import SwiftUI

/// A horizontal peak meter, green through yellow to red, with the level in
/// dB alongside.
///
/// Reads the level from AudioLevels itself, rather than being handed it,
/// so that only this view redraws as the level changes many times a
/// second - not the whole Settings window around it.
struct LevelMeter: View {
    let levels: AudioLevels
    let level: KeyPath<AudioLevels, Float>
    /// Added to the measured level, so an unsaved gain can be previewed.
    let gainDb: Double

    var body: some View {
        let floorDb = AudioLevels.floorDb
        let db = levels[keyPath: level] + Float(gainDb)
        let isClipping = db >= -0.1
        let fraction = CGFloat((min(max(db, floorDb), 0) - floorDb) / -floorDb)

        HStack(spacing: 8) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.quaternary)
                    // The colours sit at fixed levels along the whole bar
                    // (-18 dB turns yellow, -6 dB red), and the bar is
                    // revealed up to the current level.
                    LinearGradient(stops: [.init(color: .green, location: 0),
                                           .init(color: .green, location: 0.7),
                                           .init(color: .yellow, location: 0.8),
                                           .init(color: .red, location: 0.95)],
                                   startPoint: .leading, endPoint: .trailing)
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: geometry.size.width * fraction)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
            .frame(height: 8)

            Text(isClipping ? "Clip" : db > floorDb ? "\(Int(db.rounded())) dB" : "–")
                .monospacedDigit()
                .foregroundStyle(isClipping ? .red : .secondary)
                .frame(width: 52, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityValue(isClipping ? "Clipping" : db > floorDb ? "\(Int(db.rounded())) decibels" : "Silent")
    }
}
