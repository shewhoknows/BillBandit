import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

private extension UIColor {
    convenience init(hex: Int) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

struct InviteLinkCard: View {
    var title: String = "Invite link"
    var url: URL
    var caption: String = "Share this receipt link with the group."
    var onCopy: () -> Void
    var onShare: () -> Void

    var body: some View {
        ReceiptCard(eyebrow: "Bandit pass", title: title, showsPerforatedEdges: false) {
            VStack(alignment: .leading, spacing: BBSpacing.md) {
                Text(url.absoluteString)
                    .font(BBFont.label(size: 13, relativeTo: .caption))
                    .tracking(BBTracking.value(BBTracking.monoLabel, for: 13))
                    .foregroundStyle(BBColor.textPrimary)
                    .lineLimit(2)
                    .textSelection(.enabled)

                Text(caption)
                    .font(BBFont.bodyRounded(size: 14, relativeTo: .subheadline))
                    .foregroundStyle(BBColor.textFaded)

                HStack(spacing: BBSpacing.sm) {
                    SecondaryButton(title: "Copy", systemImage: "doc.on.doc", action: onCopy)
                    PrimaryButton(title: "Share", systemImage: "square.and.arrow.up", action: onShare)
                }
            }
        }
    }
}

struct FriendCodeCard: View {
    var code: String
    var caption: String = "Read it out, paste it, or share it."
    var onCopy: () -> Void
    var onShare: () -> Void

    var body: some View {
        ReceiptCard(eyebrow: "Friend code", title: "Your code", showsPerforatedEdges: false) {
            VStack(alignment: .leading, spacing: BBSpacing.md) {
                Text(code.uppercased())
                    .font(BBFont.amount(size: 36, weight: .heavy, relativeTo: .largeTitle))
                    .tracking(BBTracking.value(BBTracking.stamp, for: 36))
                    .foregroundStyle(BBColor.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, BBSpacing.xs)
                    .accessibilityLabel("Friend code \(code)")

                Text(caption)
                    .font(BBFont.bodyRounded(size: 14, relativeTo: .subheadline))
                    .foregroundStyle(BBColor.textFaded)

                HStack(spacing: BBSpacing.sm) {
                    SecondaryButton(title: "Copy", systemImage: "doc.on.doc", action: onCopy)
                    PrimaryButton(title: "Share", systemImage: "square.and.arrow.up", action: onShare)
                }
            }
        }
    }
}

struct QRCodeCard: View {
    var title: String = "Scan to join"
    var value: String
    var caption: String?

    var body: some View {
        ReceiptCard(eyebrow: "QR invite", title: title, showsPerforatedEdges: false) {
            VStack(alignment: .center, spacing: BBSpacing.md) {
                qrImage
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(BBSpacing.md)
                    .frame(maxWidth: 220, minHeight: 220)
                    .background(BBColor.blueDark, in: RoundedRectangle(cornerRadius: BBRadius.receipt, style: .continuous))
                    .accessibilityLabel("QR code")

                if let caption {
                    Text(caption)
                        .font(BBFont.bodyRounded(size: 14, relativeTo: .subheadline))
                        .foregroundStyle(BBColor.textFaded)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var qrImage: Image {
        let data = Data(value.utf8)
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else {
            return Image(systemName: "qrcode")
        }

        let colorFilter = CIFilter.falseColor()
        colorFilter.inputImage = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        colorFilter.color0 = CIColor(color: UIColor(hex: 0xFFF5DE))
        colorFilter.color1 = CIColor(color: UIColor(hex: 0x082B8F))

        let context = CIContext(options: [.useSoftwareRenderer: false])
        let image = colorFilter.outputImage ?? outputImage
        guard let cgImage = context.createCGImage(image, from: image.extent) else {
            return Image(systemName: "qrcode")
        }

        return Image(uiImage: UIImage(cgImage: cgImage))
    }
}

struct HandwrittenTextField: View {
    var title: String
    var placeholder: String
    @Binding var text: String
    var axis: Axis = .horizontal

    var body: some View {
        TextField(title, text: $text, prompt: prompt, axis: axis)
            .font(BBFont.handwriting(size: 28, relativeTo: .title3))
            .foregroundStyle(BBColor.textPrimary)
            .padding(.horizontal, BBSpacing.sm)
            .frame(minHeight: 52)
            .background(BBColor.cream.opacity(0.62), in: RoundedRectangle(cornerRadius: BBRadius.field, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: BBRadius.field, style: .continuous)
                    .stroke(BBColor.fieldBorder, style: BBBorder.field)
            }
    }

    private var prompt: Text {
        Text(placeholder)
            .font(BBFont.handwriting(size: 28, relativeTo: .title3))
            .foregroundStyle(BBColor.textFaded.opacity(0.62))
    }
}

struct HandwrittenTextEditor: View {
    var placeholder: String
    @Binding var text: String
    var minHeight: CGFloat = 120

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(BBFont.handwriting(size: 27, relativeTo: .title3))
                    .foregroundStyle(BBColor.textFaded.opacity(0.62))
                    .padding(.horizontal, BBSpacing.md)
                    .padding(.vertical, 13)
                    .allowsHitTesting(false)
            }

            TextEditor(text: $text)
                .font(BBFont.handwriting(size: 27, relativeTo: .title3))
                .foregroundStyle(BBColor.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, BBSpacing.xs)
                .padding(.vertical, BBSpacing.xs)
                .frame(minHeight: minHeight)
                .background(Color.clear)
        }
        .background(BBColor.cream.opacity(0.62), in: RoundedRectangle(cornerRadius: BBRadius.field, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: BBRadius.field, style: .continuous)
                .stroke(BBColor.fieldBorder, style: BBBorder.field)
        }
    }
}

#Preview("Invite and Input") {
    @Previewable @State var tripName = "Monsoon snacks"
    @Previewable @State var note = ""

    ScrollView {
        VStack(spacing: BBSpacing.lg) {
            FriendCodeCard(code: "BND7-RAO9", onCopy: {}, onShare: {})
            QRCodeCard(value: "https://billbandit.app/invite/BND7-RAO9", caption: "Cream on navy, ready for a table scan.")
            InviteLinkCard(url: URL(string: "https://billbandit.app/invite/BND7-RAO9")!, onCopy: {}, onShare: {})
            HandwrittenTextField(title: "Trip name", placeholder: "Trip name", text: $tripName)
            HandwrittenTextEditor(placeholder: "Add a note for the crew", text: $note)
        }
        .padding()
    }
    .background(BBColor.background)
}
