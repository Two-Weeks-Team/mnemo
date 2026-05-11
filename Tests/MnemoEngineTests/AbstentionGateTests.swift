import Testing
@testable import MnemoEngine

@Suite("AbstentionGate — recall, don't advise")
struct AbstentionGateTests {
    let gate = AbstentionGate()

    @Test("Pure recall is allowed (not abstained)")
    func recallAllowed() {
        #expect(gate.evaluate("what did the doctor say last Tuesday?") == nil)
        #expect(gate.evaluate("show me the lease document I scanned in March") == nil)
        #expect(gate.evaluate("when did I last talk to my lawyer?") == nil)
        #expect(gate.evaluate("what was the address I copied yesterday?") == nil)
    }

    @Test("Medical advice-seeking is abstained")
    func medicalAbstained() {
        #expect(gate.evaluate("should I take this medication twice a day?") == .medical)
        #expect(gate.evaluate("what disease do I have? diagnose my chest pain") == .medical)
    }

    @Test("Legal advice-seeking is abstained")
    func legalAbstained() {
        #expect(gate.evaluate("can I sue my landlord for this eviction notice?") == .legal)
        #expect(gate.evaluate("should I sign this contract?") == .legal)
    }

    @Test("Financial advice-seeking is abstained")
    func financialAbstained() {
        #expect(gate.evaluate("should I invest in this stock?") == .financial)
    }

    @Test("Immigration advice-seeking is abstained")
    func immigrationAbstained() {
        #expect(gate.evaluate("will I be deported if I miss this USCIS deadline?") == .immigration)
    }

    @Test("Emergency markers fire regardless of phrasing")
    func emergencyAbstained() {
        #expect(gate.evaluate("I want to die") == .emergency)
        #expect(gate.evaluate("how do I overdose") == .emergency)
    }

    @Test("Referral text names the right resource")
    func referralText() {
        #expect(gate.referral(for: .medical).resourceClass == "a doctor")
        #expect(gate.referral(for: .legal).resourceClass == "a lawyer")
        #expect(gate.referral(for: .emergency).reason.lowercased().contains("emergency"))
    }
}
