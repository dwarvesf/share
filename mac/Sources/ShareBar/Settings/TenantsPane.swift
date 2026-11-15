import ShareBarCore
import SwiftUI

/// Settings > Tenants: a source list with + and -, and the detail of the selected tenant.
struct TenantsPane: View {
    @ObservedObject var store: SettingsStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = SettingsTheme(scheme)
        let entries = store.tenants
        Group {
            if !store.loaded {
                HStack(spacing: 6) { SBSpinner(size: 10); Text("Reading your tenants…").font(t.bodyFont).foregroundColor(t.secondary) }
                    .frame(maxWidth: .infinity, minHeight: 360)
                    .accessibilityIdentifier("tenants-loading")
            } else if entries.isEmpty, let failure = store.failure {
                VStack(spacing: 8) {
                    Text("Couldn't read your tenants").font(t.titleFont).foregroundColor(t.label)
                    Text(failure.sentence).font(t.bodyFont).foregroundColor(t.secondary).multilineTextAlignment(.center)
                    Button("Try again") { Task { await store.refresh() } }.sbButton().accessibilityIdentifier("tenants-retry").padding(.top, 4)
                }
                .padding(.horizontal, 40)
                .frame(maxWidth: .infinity, minHeight: 360)
                .accessibilityIdentifier("tenants-failure")
            } else if entries.isEmpty {
                VStack(spacing: 8) {
                    Text("No tenants yet").font(t.titleFont).foregroundColor(t.label)
                    Text("Join your team with an invite code, or set up a hostname you own.").font(t.bodyFont).foregroundColor(t.secondary)
                    Button("Add a tenant…") { store.presentAdd(.setup) }.sbButton(.primary).accessibilityIdentifier("t-add")
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, minHeight: 360)
            } else {
                HStack(alignment: .top, spacing: 20) {
                    sourceColumn(entries, t)
                    if let detail = store.selectedDetail { TenantDetailView(store: store, detail: detail) }
                    else { Spacer() }
                }
                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 20)
                .frame(maxWidth: .infinity, minHeight: 420, alignment: .topLeading)
            }
        }
    }

    private func sourceColumn(_ entries: [ProfileEntry], _ t: SettingsTheme) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(entries, id: \.name) { entry in
                        if let detail = store.detail(of: entry) {
                            SourceRow(detail: detail, selected: store.selectedEntry?.name == entry.name) { store.select(entry.name) }
                        }
                    }
                }
            }
            .padding(4)
            .frame(width: 190, height: 300, alignment: .top)
            .background(EdgeRounded(edge: .top, radius: 7).fill(t.field))
            .overlay(EdgeRounded(edge: .top, radius: 7).stroke(t.separator, lineWidth: 1))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Tenants")
            HStack(spacing: 0) {
                barButton("plus", id: "t-add", label: "Add a tenant") { store.presentAdd(.setup) }
                Rectangle().fill(t.separator).frame(width: 1, height: 22)
                barButton("minus", id: "t-rm", label: "Remove \(store.selectedDetail?.host ?? "tenant")") {
                    if let detail = store.selectedDetail { store.confirmRemoval(detail) }
                }
                Rectangle().fill(t.separator).frame(width: 1, height: 22)
                Spacer()
            }
            .frame(width: 190, height: 22)
            .background(EdgeRounded(edge: .bottom, radius: 7).fill(t.field))
            .overlay(EdgeRounded(edge: .bottom, radius: 7).stroke(t.separator, lineWidth: 1))
        }
    }

    private func barButton(_ symbol: String, id: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                .foregroundColor(SettingsTheme(scheme).label)
                .frame(width: 28, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityLabel(label)
    }
}

private struct SourceRow: View {
    let detail: TenantDetail
    let selected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = SettingsTheme(scheme)
        Button(action: action) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(detail.host).font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(selected ? .white : t.label).lineLimit(1).truncationMode(.middle)
                    Text(detail.listLine).font(t.metaFont)
                        .foregroundColor(selected ? .white : t.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if detail.needsLook {
                    Circle().fill(selected ? Color.white : t.attention).frame(width: 7, height: 7)
                        .accessibilityLabel("needs a look")
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 5).fill(selected ? t.color(Tokens.palette(scheme == .dark ? .dark : .light).semantic.info) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tenant-\(detail.profile)")
        .accessibilityLabel("\(detail.host), \(detail.listLine)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct TenantDetailView: View {
    @ObservedObject var store: SettingsStore
    let detail: TenantDetail
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = SettingsTheme(scheme)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(detail.host).font(.system(size: 17, weight: .semibold, design: .monospaced)).foregroundColor(t.label)
                    .lineLimit(1).truncationMode(.middle)
                    .accessibilityIdentifier("detail-host")
                if detail.actions.contains(.openInBrowser) {
                    Button { store.openInBrowser(detail) } label: {
                        Image(systemName: "arrow.up.forward.square").font(.system(size: 13)).foregroundColor(t.secondary)
                            .frame(width: 26, height: 26).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open in browser")
                    .accessibilityLabel("Open \(detail.host) in your browser")
                    .accessibilityIdentifier("tb-openb")
                }
                HStack(spacing: 6) {
                    StatusMark(tone: detail.status.tone)
                    Text(detail.status.word).font(t.bodyFont).foregroundColor(t.secondary).lineLimit(1)
                }
                .padding(.leading, 4)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("detail-status")
                Spacer(minLength: 0)
            }
            .padding(.bottom, 14)
            if let banner = detail.banner { bannerView(banner, t) }
            if let callout = detail.callout { calloutView(callout, t) }
            Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 8) {
                row("Your role", detail.roleWord, t)
                row("Storage", detail.storage, t)
                if let members = detail.members { row("Members", members, t) }
                row("Served from", detail.servedFrom, t)
                if let key = detail.key { row("Key", key, t) }
            }
            .padding(.bottom, 18)
            HStack(spacing: 8) {
                ForEach(buttons, id: \.self) { action in
                    Button(action.title) { store.perform(action, on: detail) }
                        .sbButton(kind(for: action))
                        .accessibilityIdentifier("tb-\(action.rawValue)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// The bottom row: everything but the actions the head and the callout already carry.
    private var buttons: [TenantAction] {
        detail.actions.filter { ![.resume, .rollBack, .openInBrowser].contains($0) }
    }

    private func kind(for action: TenantAction) -> SBButtonKind {
        guard detail.callout == nil, detail.banner == nil else { return .normal }
        return action == .start ? .primary : .normal
    }

    private func row(_ label: String, _ value: String, _ t: SettingsTheme) -> some View {
        GridRow {
            Text(label).font(t.bodyFont).foregroundColor(t.secondary).frame(width: 96, alignment: .leading)
            Text(value).font(t.bodyFont).foregroundColor(t.label).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bannerView(_ banner: TenantBanner, _ t: SettingsTheme) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 14)).foregroundColor(t.attentionInk)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.text).font(.system(size: 13, weight: .semibold)).foregroundColor(t.label)
                if let text = banner.detail { Text(text).font(t.metaFont).foregroundColor(t.secondary) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(t.attention.opacity(0.10)).background(RoundedRectangle(cornerRadius: 8).fill(t.field)))
        .padding(.bottom, 16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail-banner")
    }

    private func calloutView(_ callout: TenantCallout, _ t: SettingsTheme) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.clockwise").font(.system(size: 14)).foregroundColor(t.attentionInk)
            VStack(alignment: .leading, spacing: 2) {
                Text(callout.title).font(.system(size: 13, weight: .semibold)).foregroundColor(t.label)
                Text(callout.detail).font(t.metaFont).foregroundColor(t.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Spacer()
                    if callout.canRollBack {
                        Button("Roll back") { store.perform(.rollBack, on: detail) }.sbButton().accessibilityIdentifier("tb-rollback")
                    }
                    if callout.canResume {
                        Button("Resume") { store.perform(.resume, on: detail) }.sbButton(.primary).accessibilityIdentifier("tb-resume")
                    }
                }
                .padding(.top, 8)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(t.attention.opacity(0.10)).background(RoundedRectangle(cornerRadius: 8).fill(t.field)))
        .padding(.bottom, 16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail-callout")
    }
}
