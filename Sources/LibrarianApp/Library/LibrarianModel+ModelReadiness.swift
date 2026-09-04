import LibrarianCore

extension LibrarianModel {
    /// Product-level readiness is stricter than the generic "some Tier-2
    /// provider exists" status. Balanced/Quality should not tell a person they
    /// are ready merely because one encoder or fallback happens to be present.
    func isLocalModelProfileReady(_ profile: LocalModelProfile) -> Bool {
        switch profile {
        case .fast:
            return true
        case .balanced:
            let required = [
                LocalModelStack.siglip2.id,
                LocalModelStack.dinov3.id,
                LocalModelStack.miniCPM.id,
            ]
            return isTier2Provisioned && required.allSatisfy(specialistProvisionedIDs.contains)
        case .quality:
            let required = [
                LocalModelStack.siglip2.id,
                LocalModelStack.dinov3.id,
                LocalModelStack.miniCPM.id,
                LocalModelStack.lfm.id,
            ]
            return isTier2Provisioned && required.allSatisfy(specialistProvisionedIDs.contains)
        }
    }
}
