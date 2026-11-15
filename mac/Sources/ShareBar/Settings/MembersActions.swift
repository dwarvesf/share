import ShareBarCore
import SwiftUI

/// Settings > Members: reading the roster and running the verbs of a row menu (SPEC-009
/// TASK-4b19). Every verb goes through the keyed path the other admin verbs use, so an asked
/// key reaches only that one child.
extension SettingsStore {
    /// The tenant the tab shows: the popover's current tenant when it is an admin tenant with
    /// members, else the first one.
    var membersProfile: ProfileEntry? {
        let admins = tenants.filter { entry in
            guard let state = entry.state, state.tier == "t2" else { return false }
            let role = Role(raw: state.role)
            return role != .member && role != .unset && role != .unknown && role != .migrated
        }
        return admins.first { $0.name == popoverPrefs.currentProfile } ?? admins.first
    }

    /// The tab opened: read the roster, asking for the admin key first when its source says so.
    func requestMembers() {
        guard let entry = membersProfile, members.shouldRequest() else { return }
        members.begin(profile: entry.name)
        let asks = keysNeedingAsk([.admin], profile: entry.name)
        members.askPending = !asks.isEmpty
        collectKeys(asks, asked: [:],
                    purpose: "Share Bar uses it to read the members and forgets it right away.") { [weak self] keys in
            guard let self else { return }
            self.members.askPending = false
            Task { await self.loadMembers(profile: entry.name, keys: keys) }
        }
    }

    /// `member ls --json`. A failure shows the CLI's sentence in place of the list.
    func loadMembers(profile: String, keys: [String: String] = [:]) async {
        let argv = MembersModel.listArgv(profile: profile)
        let request = members.newRequest()
        let result: CLIResult
        if keys.isEmpty {
            result = await readCLI(argv)
        } else {
            result = await AskedKeyCommand(argv: argv, environment: keys).spawn().result
        }
        guard members.isCurrent(request) else { return }
        guard result.status == 0, let list = MemberList.decode(result.stdout) else {
            members.failed(MembersModel.failureSentence(result), profile: profile)
            onMembers(nil, profile)
            return
        }
        members.loaded(list, profile: profile)
        onMembers(list, profile)
    }

    /// One row-menu item.
    func memberVerb(_ verb: MemberVerb, member: MemberRecord) {
        members.closeMenu()
        guard let profile = members.profile ?? membersProfile?.name, let argv = MembersModel.argv(verb, member: member, profile: profile) else { return }
        let host = entry(profile)?.state?.host ?? profile
        let name = MembersModel.display(member.name)
        switch verb {
        case .pause:
            presentPause(member: member.name, profile: profile, display: name)
        case .rm:
            presentRemoveMember(member: member.name, profile: profile, display: name)
        case .resume:
            runKeyed(argv, kinds: [.admin], profile: profile, host: host, done: "\(name) is resumed.")
        case .finish:
            runKeyed(argv, kinds: [.admin, .minter], profile: profile, host: host, done: "\(name): finished.")
        case .invite:
            runForCode(argv, kinds: [.admin, .minter], profile: profile, member: name, rotate: false)
        case .rotate:
            sheet = .confirm(Impact.rotate(member: name), .runForCode(argv: argv, kinds: [.admin, .minter], profile: profile, member: name, rotate: true))
        case .renew:
            sheet = .confirm(Impact.renew(member: name), .runKeyed(argv: argv, kinds: [.admin, .minter], profile: profile, done: "\(name)'s key is renewed."))
        case .purge:
            sheet = .confirm(Impact.purge(member: name), .runKeyed(argv: argv, kinds: [.admin], profile: profile, done: "\(name)'s record is deleted."))
        }
    }

    /// A verb that prints a code to send: run it, then show the code once.
    func runForCode(_ argv: [String], kinds: [KeyKind], profile: String, member: String, rotate: Bool) {
        let host = entry(profile)?.state?.host ?? profile
        collectKeys(keysNeedingAsk(kinds, profile: profile), asked: [:],
                    purpose: "Share Bar uses it for this one action and forgets it right away.") { [weak self] keys in
            guard let self else { return }
            Task {
                let result = await self.runWith(argv, keys: keys)
                guard result.status == 0, let code = InviteForm.code(fromStdout: result.stdout) else {
                    if result.status != 0 { self.showFailure(result, host: host) }
                    await self.loadMembers(profile: profile, keys: keys)
                    return
                }
                self.sheet = .code(CodeSheet(member: member, code: code, rotate: rotate, ttlDays: 7))
                await self.loadMembers(profile: profile, keys: keys)
            }
        }
    }

    func copyMemberCode(_ code: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }
}

extension SettingsStore {
    /// "Open Members" from a needs-a-look line: show the member's row marked, once the roster is read.
    func pointAtMember(_ name: String) {
        members.point(at: name)
    }
}
