import SwiftUI

/// The sender and their words stay readable after the burst has settled.
struct BumpArrivalView: View {
    // MARK: Internal

    let moment: BumpReceivedMoment

    var body: some View {
        TimelineView(.animation(
            minimumInterval: 1 / 60,
            paused: effects.run == nil || effects.run?.frozenTime != nil
        )) { clock in
            let run = effects.run
            let motion = run
                .map { BumpEffectMotion.sample($0.effect, at: $0.elapsed(at: clock.date), reduced: $0.reduced) }
                ?? BumpEffectMotion()
            VStack(spacing: 0) {
                FirstlightAvatar(url: moment.avatarURL, name: moment.name, size: 76)
                    .scaleEffect(x: motion.scaleX, y: motion.scaleY)
                    .rotationEffect(.degrees(motion.rotation))
                    .offset(x: motion.x, y: motion.y)
                    .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
                Text("\(moment.name) says")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 15)
                Text(moment.title)
                    .font(.system(size: 29, weight: .semibold, design: .rounded))
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 105)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(moment.name) says \(moment.title)")
        .overlay(alignment: .topTrailing) {
            BumpGlassButton(prominent: false, circular: true) { effects.dismissIncoming() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .medium)).frame(width: 20, height: 20)
            }
            .padding(12).accessibilityLabel("Dismiss incoming bump")
        }
    }

    // MARK: Private

    @ObservedObject private var effects = BumpEffects.shared
}
