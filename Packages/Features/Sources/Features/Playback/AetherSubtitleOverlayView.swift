#if os(tvOS)
    import AetherEngine
    import Combine
    import OSLog
    import UIKit

    /// Spike #60: draws the trial engine's subtitle cues over the video.
    ///
    /// The engine decodes every embedded subtitle track itself and publishes
    /// the cues; in fullscreen the host is expected to draw them. Image cues
    /// (PGS, VobSub) go where the disc authored them. Text cues are drawn as
    /// plain outlined lines at the bottom: no ASS styling or placement, and
    /// no system caption style, in this pass.
    @MainActor
    final class AetherSubtitleOverlayView: UIView {
        private static let logger = Logger(subsystem: "com.justinlascelle.jellyshark", category: "Playback")

        /// Where the picture sits inside this view. Empty means "all of it".
        var videoRect: () -> CGRect = { .zero }

        private let label = UILabel()
        private var imageViews: [UIImageView] = []
        private var cues: [SubtitleCue] = []
        private var shownCueIDs: [Int] = []
        private var hasLoggedFirstCue = false
        private var subscriptions: Set<AnyCancellable> = []

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isUserInteractionEnabled = false
            label.numberOfLines = 0
            label.textAlignment = .center
            label.layer.shadowColor = UIColor.black.cgColor
            label.layer.shadowOpacity = 0.9
            label.layer.shadowRadius = 4
            label.layer.shadowOffset = .zero
            label.isHidden = true
            addSubview(label)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        func bind(to engine: AetherEngine) {
            subscriptions.removeAll()
            // `@Published` emits in willSet, so each sink uses the value it
            // is handed rather than reading the engine back.
            engine.$subtitleCues
                .sink { [weak self, weak engine] cues in
                    guard let self else { return }
                    self.cues = cues
                    render(at: engine?.clock.sourceTime ?? 0)
                }
                .store(in: &subscriptions)
            // Cues are stamped in the file's own timestamps, which is what
            // `sourceTime` follows; the player's clock is shifted from it.
            engine.clock.$sourceTime
                .sink { [weak self] time in
                    self?.render(at: time)
                }
                .store(in: &subscriptions)
            engine.$activeSubtitleTrackIndex
                .removeDuplicates()
                .sink { [weak self] _ in
                    self?.hasLoggedFirstCue = false
                }
                .store(in: &subscriptions)
        }

        private func render(at time: Double) {
            let active = cues.filter { $0.startTime <= time && time < $0.endTime }
            let ids = active.map(\.id)
            guard ids != shownCueIDs else { return }
            shownCueIDs = ids

            imageViews.forEach { $0.removeFromSuperview() }
            imageViews = []
            var lines: [String] = []
            let picture = pictureRect

            for cue in active {
                switch cue.body {
                case let .text(text):
                    lines.append(text)
                case let .richText(runs):
                    lines.append(runs.map(\.text).joined())
                case let .image(image):
                    let view = UIImageView(image: UIImage(cgImage: image.cgImage))
                    view.frame = Self.frame(for: image, in: picture)
                    insertSubview(view, belowSubview: label)
                    imageViews.append(view)
                }
            }
            layoutText(lines.joined(separator: "\n"), in: picture)

            if !active.isEmpty, !hasLoggedFirstCue {
                hasLoggedFirstCue = true
                Self.logger.info("[aether] first subtitle cue drawn: text=\(lines.count) image=\(self.imageViews.count) at \(time, format: .fixed(precision: 1))s")
            }
        }

        private var pictureRect: CGRect {
            let rect = videoRect()
            return rect.isEmpty ? bounds : rect
        }

        /// The cue's rect is normalized against the subtitle canvas. The
        /// canvas maps onto the picture width-aligned and centre-anchored,
        /// as the engine's docs specify, so a cropped rip keeps cues where
        /// the disc put them.
        private static func frame(for image: SubtitleImage, in picture: CGRect) -> CGRect {
            var canvas = picture
            if image.canvasSize.width > 0, image.canvasSize.height > 0 {
                let height = picture.width * image.canvasSize.height / image.canvasSize.width
                canvas = CGRect(x: picture.minX, y: picture.midY - height / 2, width: picture.width, height: height)
            }
            return CGRect(
                x: canvas.minX + image.position.minX * canvas.width,
                y: canvas.minY + image.position.minY * canvas.height,
                width: image.position.width * canvas.width,
                height: image.position.height * canvas.height,
            )
        }

        private func layoutText(_ text: String, in picture: CGRect) {
            guard !text.isEmpty else {
                label.attributedText = nil
                label.isHidden = true
                return
            }
            // Sized against the picture so a 4:3 title keeps its lines
            // inside the frame. A negative stroke width fills and outlines.
            let fontSize = max(28, picture.height * 0.05)
            label.attributedText = NSAttributedString(string: text, attributes: [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: UIColor.white,
                .strokeColor: UIColor.black,
                .strokeWidth: -3,
            ])
            label.isHidden = false

            let width = picture.width * 0.8
            let size = label.sizeThatFits(CGSize(width: width, height: picture.height))
            label.frame = CGRect(
                x: picture.midX - width / 2,
                y: picture.maxY - picture.height * 0.07 - size.height,
                width: width,
                height: size.height,
            )
        }
    }
#endif
