import ClamshellInput
import ClamshellWire
import QuartzCore
import SwiftUI
import UIKit

/// The Duo's posture (ADR-0012): hinge status + division region + scene bounds → `PostureInference`,
/// debounced 150 ms for layout and 600 ms for the Mac's display mode. A pin overrides it for the session.
@MainActor
@Observable
final class PostureModel {
    private(set) var layout: Posture
    private(set) var display: Posture
    private(set) var inputs = PostureInputs(bounds: CGSize(width: 1, height: 2))
    /// The division (fold) region in the root view's coordinates, so nothing interactive goes there.
    private(set) var fold: CGRect?
    /// Whether this device reports a hinge at all (false on the simulator and on other phones).
    private(set) var hasHinge = false
    var pinned: Posture? {
        get { debouncer.pinned }
        set { debouncer.pin(newValue); publish() }
    }
    /// Called with the new display posture once it has held 600 ms (or when a pin changes it).
    var onDisplayChange: ((Posture) -> Void)?

    @ObservationIgnored private var debouncer: PostureDebouncer
    @ObservationIgnored private var timer: Timer?

    init() {
        let initial = PostureInference.infer(PostureInputs(bounds: CGSize(width: 1, height: 2)))
        debouncer = PostureDebouncer(initial: initial, nowNs: Self.now())
        layout = initial
        display = initial
    }

    static func now() -> UInt64 { UInt64(CACurrentMediaTime() * 1e9) }

    func update(hinge: PostureInputs.Hinge? = nil, division: CGRect?? = nil, bounds: CGSize? = nil) {
        if let hinge { inputs.hinge = hinge; hasHinge = hinge != .unknown }
        if let division { inputs.division = division; fold = division }
        if let bounds, bounds.width > 0, bounds.height > 0 { inputs.bounds = bounds }
        debouncer.observe(PostureInference.infer(inputs), nowNs: Self.now())
        publish()
        scheduleTick()
    }

    private func scheduleTick() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.debouncer.tick(nowNs: Self.now())
                self.publish()
                if self.debouncer.ui == self.debouncer.display, self.debouncer.display == PostureInference.infer(self.inputs) {
                    self.timer?.invalidate()
                    self.timer = nil
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func publish() {
        let l = debouncer.effective
        let d = debouncer.pinned ?? debouncer.display
        if l != layout { layout = l }
        if d != display {
            display = d
            onDisplayChange?(d)
        }
    }

    /// The Mac's virtual display for a posture (docs/video.md §5). Book keeps the laptop picture: it spans both
    /// pages above the split keyboard, so turning the Duo sideways doesn't resize the Mac's screen.
    static func mode(for p: Posture) -> DisplayMode {
        switch p {
        case .laptop: .laptop
        case .flat: .flat
        case .book: .laptop
        case .cover: .cover
        }
    }
}

/// An invisible view that feeds the model: a `UIHingeInteraction` for the hinge status, and the
/// division region and bounds on every layout pass.
struct PostureSensor: UIViewRepresentable {
    let model: PostureModel
    func makeUIView(context: Context) -> PostureSensorView { PostureSensorView(model: model) }
    func updateUIView(_ view: PostureSensorView, context: Context) {}
}

final class PostureSensorView: UIView {
    private let model: PostureModel

    init(model: PostureModel) {
        self.model = model
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        if #available(iOS 27.1, *) {
            addInteraction(UIHingeInteraction { [weak self] _, update in
                guard let self else { return }
                let hinge: PostureInputs.Hinge
                switch update.hinge?.status {
                case .closed: hinge = .closed
                case .partiallyOpen: hinge = .partiallyOpen
                case .fullyOpen: hinge = .fullyOpen
                default: hinge = .unknown
                }
                self.model.update(hinge: hinge)
                self.setNeedsLayout()
            })
        }
    }
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        var division: CGRect?
        if #available(iOS 27.1, *) {
            division = reservedRegions(kind: .division, options: .includeInactive).first?.frame
        }
        model.update(division: .some(division), bounds: bounds.size)
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        setNeedsLayout()
    }
}
