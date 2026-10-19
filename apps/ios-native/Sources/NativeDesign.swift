import SwiftUI

enum NativeAppearance: String, CaseIterable {
    case system, light, dark
    var title: String { switch self { case .system: return "시스템 설정"; case .light: return "라이트"; case .dark: return "다크" } }
    var colorScheme: ColorScheme? { switch self { case .system: return nil; case .light: return .light; case .dark: return .dark } }
}

struct NativeAppearancePicker: View {
    var compact = false
    @AppStorage("jaegun.appearance") private var appearance = "system"
    var body: some View {
        if compact {
            Menu {
                selection
            } label: {
                Image(systemName: "circle.lefthalf.filled").font(.title3)
                    .foregroundStyle(NativePalette.forest).frame(width: 44, height: 44)
            }.accessibilityLabel("화면 모드").accessibilityValue(NativeAppearance(rawValue: appearance)?.title ?? "시스템 설정")
        } else { selection }
    }
    private var selection: some View {
        Picker("화면 모드", selection: $appearance) {
            ForEach(NativeAppearance.allCases, id: \.rawValue) { mode in Text(mode.title).tag(mode.rawValue) }
        }
    }
}

// Native equivalents of apps/web/src/theme.css; the web product is the visual source.
enum NativePalette {
    static func token(_ light: UInt, _ dark: UInt) -> Color {
        Color(UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
    static let canvas = token(0xf7f5ef, 0x101814)
    static let surface = token(0xfffefa, 0x19241f)
    static let ink = token(0x20372f, 0xf0f5f0)
    static let muted = token(0x5f6d65, 0xb5c5ba)
    static let line = token(0xdce4da, 0x3b5043)
    static let forest = token(0x286044, 0xa6d889)
    static let solidGreen = token(0x245c46, 0x245c46)
    static let orange = token(0x96500b, 0xffba70)
    static let blue = token(0x09668e, 0x7ed0fa)
    static let noticeAccent = token(0xfc8401, 0xfc8401)
    static let leafAccent = token(0x67b42a, 0x67b42a)
    static let skyAccent = token(0x0498e1, 0x0498e1)
}

struct NativeBrandHeader: View {
    var compact = false
    var body: some View {
        HStack(spacing: 10) {
            Image("JaegunBrandMark").renderingMode(.original).resizable().scaledToFit()
                .frame(width: compact ? 25 : 30, height: compact ? 32 : 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("재건 공동체").font(compact ? .headline : .title3.bold()).foregroundStyle(NativePalette.ink)
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 3) {
                Capsule().fill(NativePalette.noticeAccent)
                Capsule().fill(NativePalette.leafAccent)
                Capsule().fill(NativePalette.skyAccent)
            }.frame(width: compact ? 44 : 58, height: 3).accessibilityHidden(true)
        }
    }
}

struct NativeCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(NativePalette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(NativePalette.line) }
    }
}

struct NativePrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).multilineTextAlignment(.center)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(Color.white)
            .background(NativePalette.solidGreen, in: RoundedRectangle(cornerRadius: 12))
            .opacity(!enabled ? 0.45 : configuration.isPressed ? 0.75 : 1)
    }
}

private struct NativeAuthFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.textFieldStyle(.plain).padding(14).frame(minHeight: 52)
            .foregroundStyle(NativePalette.ink)
            .background(NativePalette.canvas, in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(NativePalette.line) }
    }
}

extension View {
    func nativeAuthFieldStyle() -> some View { modifier(NativeAuthFieldStyle()) }
}

struct NativeConsentRow: View {
    let document: NativeLegalDocument
    let hasRead: Bool
    @Binding var accepted: Bool
    let open: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 9) {
                NativeCheckbox(selected: accepted, enabled: hasRead, label: document.title + "에 동의합니다") { accepted.toggle() }
                VStack(alignment: .leading, spacing: 5) {
                    Text("[필수] " + document.consentLabel).font(.subheadline.weight(.semibold)).foregroundStyle(NativePalette.ink)
                    Text(document.summary).font(.caption).foregroundStyle(NativePalette.muted).lineSpacing(3)
                    Text("문서 버전: " + document.version).font(.caption).foregroundStyle(NativePalette.muted)
                }.padding(.top, 9)
            }
            Button(action: open) {
                Text(document.title + " 전문 보기").font(.caption.weight(.semibold)).underline()
                    .foregroundStyle(NativePalette.forest).frame(minHeight: 44, alignment: .leading)
            }.buttonStyle(.plain).padding(.leading, 40)
            if !hasRead { Text("본문 확인 후 동의할 수 있습니다.").font(.caption2).foregroundStyle(NativePalette.muted).padding(.leading, 40) }
        }
    }
}

private struct NativePageStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.scrollContentBackground(.hidden).background(NativePalette.canvas)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(NativePalette.surface, for: .navigationBar)
    }
}

struct NativeCheckbox: View {
    let selected: Bool
    var enabled = true
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: selected ? "checkmark.square.fill" : "square")
                .font(.system(size: 22)).foregroundStyle(selected ? NativePalette.forest : NativePalette.muted)
                .frame(width: 44, height: 44)
        }.buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.55)
            .accessibilityLabel(label).accessibilityValue(selected ? "동의함" : "동의하지 않음")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct NativeGoogleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.weight(.bold)).frame(maxWidth: .infinity, minHeight: 54)
            .foregroundStyle(Color(red: 0.12, green: 0.12, blue: 0.12))
            .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color(red: 0.85, green: 0.86, blue: 0.87)) }
            .opacity(!enabled ? 0.55 : configuration.isPressed ? 0.8 : 1)
    }
}
extension View {
    func nativePageStyle() -> some View { modifier(NativePageStyle()) }
}

struct NativePostSummary: View {
    let post: [String: Any]
    private var author: String { nativeText(post, "author_label", fallback: "공동체 회원") }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Text(String(author.prefix(1))).font(.caption.bold())
                    .frame(width: 32, height: 32).background(NativePalette.forest.opacity(0.10), in: Circle())
                    .foregroundStyle(NativePalette.forest).accessibilityHidden(true)
                Text(author).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 4)
                if post["is_pinned"] as? Bool == true {
                    Label("공지", systemImage: "pin.fill").font(.caption.weight(.semibold))
                        .foregroundStyle(NativePalette.orange).padding(.horizontal, 8).padding(.vertical, 5)
                        .background(NativePalette.orange.opacity(0.08), in: Capsule())
                }
            }
            Text(nativeText(post, "title", fallback: "제목 없음")).font(.headline).foregroundStyle(.primary).lineLimit(3)
            Text(nativeText(post, "body")).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
        }.padding(.vertical, 12)
    }
}
