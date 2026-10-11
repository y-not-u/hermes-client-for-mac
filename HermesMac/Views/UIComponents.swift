import SwiftUI
import AppKit

// MARK: - Profile Avatar & Color Palettes

public struct ProfileAvatar: View {
    public let name: String
    public let displayName: String
    public var size: CGFloat = 40
    public var cornerRadius: CGFloat = 11
    public var isSelected: Bool = false

    public init(name: String, displayName: String? = nil, size: CGFloat = 40, cornerRadius: CGFloat = 11, isSelected: Bool = false) {
        self.name = name
        self.displayName = displayName ?? name
        self.size = size
        self.cornerRadius = cornerRadius
        self.isSelected = isSelected
    }

    private var palette: (gradient: [Color], shadow: Color) {
        let palettes: [(gradient: [Color], shadow: Color)] = [
            ([Color(red: 0.28, green: 0.48, blue: 0.96), Color(red: 0.16, green: 0.32, blue: 0.86)], Color(red: 0.20, green: 0.40, blue: 0.90)),
            ([Color(red: 0.58, green: 0.35, blue: 0.92), Color(red: 0.42, green: 0.18, blue: 0.82)], Color(red: 0.50, green: 0.25, blue: 0.88)),
            ([Color(red: 0.08, green: 0.72, blue: 0.65), Color(red: 0.04, green: 0.55, blue: 0.50)], Color(red: 0.06, green: 0.62, blue: 0.58)),
            ([Color(red: 0.96, green: 0.56, blue: 0.16), Color(red: 0.88, green: 0.36, blue: 0.10)], Color(red: 0.92, green: 0.46, blue: 0.12)),
            ([Color(red: 0.94, green: 0.32, blue: 0.55), Color(red: 0.82, green: 0.18, blue: 0.42)], Color(red: 0.88, green: 0.24, blue: 0.48)),
            ([Color(red: 0.12, green: 0.68, blue: 0.94), Color(red: 0.06, green: 0.50, blue: 0.84)], Color(red: 0.08, green: 0.58, blue: 0.88)),
            ([Color(red: 0.24, green: 0.74, blue: 0.46), Color(red: 0.14, green: 0.58, blue: 0.34)], Color(red: 0.18, green: 0.65, blue: 0.40)),
            ([Color(red: 0.40, green: 0.48, blue: 0.64), Color(red: 0.26, green: 0.32, blue: 0.48)], Color(red: 0.32, green: 0.38, blue: 0.54))
        ]
        let hash = abs(name.isEmpty ? displayName.hashValue : name.hashValue)
        return palettes[hash % palettes.count]
    }

    private var initial: String {
        let source = displayName.isEmpty ? name : displayName
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "H" }
        return String(first).uppercased()
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(LinearGradient(colors: palette.gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: isSelected ? palette.shadow.opacity(0.35) : Color.black.opacity(0.08), radius: isSelected ? 5 : 2, y: isSelected ? 2 : 1)

            Text(initial)
                .font(.system(size: size * 0.46, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
        }
        .frame(width: size, height: size)
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(isSelected ? Color.white.opacity(0.85) : Color.white.opacity(0.2), lineWidth: isSelected ? 2 : 0.8)
        }
    }
}

// MARK: - Connection Status Badge

public struct ConnectionStatusBadge: View {
    public let connected: Bool
    public let connecting: Bool
    public let text: String

    public init(connected: Bool, connecting: Bool, text: String) {
        self.connected = connected
        self.connecting = connecting
        self.text = text
    }

    public var body: some View {
        HStack(spacing: 5) {
            if connecting {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Circle()
                    .fill(connected ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
            }
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(connecting ? .secondary : (connected ? Color.green : Color.orange))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            (connecting ? Color.secondary : (connected ? Color.green : Color.orange)).opacity(0.1),
            in: Capsule()
        )
    }
}

// MARK: - Mac Keyboard KeyCap

public struct KeyCap: View {
    public let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 3.5, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.22), lineWidth: 0.5)
            }
    }
}

// MARK: - Interactive Copy Button

public struct CopyButton: View {
    public let text: String
    public var labelText: String = "复制"
    public var isDark: Bool = false
    @State private var copied = false

    public init(text: String, labelText: String = "复制", isDark: Bool = false) {
        self.text = text
        self.labelText = labelText
        self.isDark = isDark
    }

    public var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .medium))
                Text(copied ? "已复制" : labelText)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(copied ? Color.green : (isDark ? Color(red: 0.75, green: 0.80, blue: 0.88) : Color.secondary))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                copied ? Color.green.opacity(0.18) : (isDark ? Color.white.opacity(0.08) : Color.primary.opacity(0.04)),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .help(copied ? "已复制到剪贴板" : "复制内容")
        .animation(.easeInOut(duration: 0.15), value: copied)
    }
}

// MARK: - Empty State Suggestion Card

public struct SuggestionCard: View {
    public let icon: String
    public let title: String
    public let subtitle: String
    public let action: () -> Void

    @State private var isHovered = false

    public init(icon: String, title: String, subtitle: String, action: @escaping () -> Void) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(.tint)
                    .frame(width: 32, height: 32)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(isHovered ? 1 : 0)
            }
            .padding(10)
            .background(
                isHovered ? Color.secondary.opacity(0.08) : Color.secondary.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isHovered ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.06), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
