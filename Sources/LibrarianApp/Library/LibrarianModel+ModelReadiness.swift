import LibrarianCore

extension LibrarianModel {
    /// Product-level readiness is stricter than the generic "some Tier-2
    /// provider exists" status. Consumer profiles intentionally require only
    /// public checkpoints: optional gated models must never block Analyze.
    func isLocalModelProfileReady(_ profile: LocalModelProfile) -> Bool {
        switch profile {
        case .fast:
            return true
        case .balanced:
            let required = [
                LocalModelStack.siglip2Base.id,
                LocalModelStack.miniCPM.id,
            ]
            return isTier2Provisioned && required.allSatisfy(specialistReadyIDs.contains)
        case .quality:
            let required = [
                LocalModelStack.siglip2So400m.id,
                LocalModelStack.miniCPM.id,
                LocalModelStack.lfm.id,
            ]
            return isTier2Provisioned && required.allSatisfy(specialistReadyIDs.contains)
        }
    }
}
