//
//  SwingSelection.swift
//  Swingline
//
//  The pieces the swing list needs for a fixed 4:3 tile and for bulk delete.
//
//  These live in Views rather than in App/Models.swift on purpose. Selection is
//  screen state: which cards are ticked right now, gone the moment the golfer
//  leaves. It is not part of a swing and has no business being persisted, so it
//  stays as a Set of ids in the list view's own @State and these views take it
//  as parameters.
//
//  WHAT IS HERE
//
//    SwingThumbBox        the 4:3 tile, centre cropped, with the tick overlay
//    SwingSelectionTick   the circle and checkmark, animated
//    SelectionTrashButton the top nav control, trash then Done
//    BulkDeleteBar        the bottom bar, count plus Delete and Cancel
//
//  Nothing here reaches into AppStore except to read a thumbnail path. The
//  deleting is done by the list view calling store.deleteSwings(ids:), so the
//  one place that mutates the history stays the store.
//
//  House rule: no em dashes anywhere.
//

import SwiftUI
import UIKit

// MARK: - Thumbnail loading

/*
  A tiny cache in front of UIImage(contentsOfFile:).

  A grid re draws its cards on every selection tap, and decoding a JPEG off disk
  inside body means a hitch per tap once a golfer has a few dozen swings. Keyed
  by path, cleared by the system under pressure, which is what NSCache is for.
*/
private final class ThumbCache {
    static let shared = ThumbCache()
    private let cache = NSCache<NSString, UIImage>()

    init() { cache.countLimit = 240 }

    func image(at path: String) -> UIImage? {
        if let hit = cache.object(forKey: path as NSString) { return hit }
        guard let image = UIImage(contentsOfFile: path) else { return nil }
        cache.setObject(image, forKey: path as NSString)
        return image
    }

    // Call after deleting, so a reused id cannot show the previous tile.
    func forget(_ path: String) { cache.removeObject(forKey: path as NSString) }
}

// MARK: - The 4:3 tile

/*
  Every swing tile in the app, at exactly one shape.

  The box is clamped to AppStore.thumbAspect and the image fills it with
  scaledToFill inside a clip, so the frame never takes the image's intrinsic
  aspect and the metadata under it always starts at the same y. The stored file
  is already cropped to 4:3 by SwingThumbnail, so scaledToFill has nothing left
  to trim in the normal case; it is there to hold the shape for tiles written by
  an older build.

  contentShape means the whole tile is tappable, including the turf showing
  through a failed load.
*/
struct SwingThumbBox: View {
    let path: String?
    var selectionMode: Bool = false
    var isSelected: Bool = false
    var cornerRadius: CGFloat = Tok.rMd

    var body: some View {
        ZStack(alignment: .topTrailing) {
            /*
              One fixed 4:3 landscape box, locked with the literal ratio so there
              is no ambiguity about which axis wins.

              A tinted Color is the base: it has no intrinsic size, so it takes
              the grid cell's width and aspectRatio(4/3, .fit) derives the height
              from it, giving width over height of 4:3, landscape, every time. The
              image then fills that box with scaledToFill and is clipped, so a
              source of any shape is centre cropped to the box rather than
              stretching it. This is the whole aspect fix: the box owns the shape,
              the image never does.

              4.0 / 3.0 is written out rather than read from a constant so this
              file states its own shape. It matches AppStore.thumbSize, 640x480.
            */
            Tok.turf800
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .overlay {
                    if let path, let image = ThumbCache.shared.image(at: path) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        // An empty tile still says what it is rather than
                        // sitting there as a grey hole.
                        Image(systemName: "figure.golf")
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(Tok.bone3.opacity(0.5))
                    }
                }
                .clipped()

            if selectionMode {
                SwingSelectionTick(isSelected: isSelected)
                    .padding(Tok.s2)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(isSelected ? Tok.citrus : Tok.line, lineWidth: isSelected ? 2 : 1)
        }
        .contentShape(Rectangle())
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: selectionMode)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: isSelected)
    }
}

// MARK: - The tick

/*
  Top trailing, on the same side as the trash button that started selection, so
  the eye travels down from the control to the things it acts on.

  The scrim under the circle is not decoration: a tick has to read on a bright
  sky and on a dark treeline, and a stroke alone disappears on one of them.
*/
struct SwingSelectionTick: View {
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isSelected ? Tok.citrus : Color.black.opacity(0.38))
                .overlay {
                    Circle().strokeBorder(
                        isSelected ? Color.clear : Color.white.opacity(0.85),
                        lineWidth: 1.5
                    )
                }
                .frame(width: 26, height: 26)

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Tok.turf900)
            }
        }
        // The dot is 26pt so it does not swallow the tile, the hit area is 44pt
        // because a thumb is not 26pt wide.
        .frame(width: 44, height: 44, alignment: .center)
        .contentShape(Rectangle())
        .scaleEffect(isSelected ? 1 : 0.92)
        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - Top nav control

/*
  Trash to enter selection, Done to leave it.

  Both states are the same button in the same place, which is the Mail and Photos
  behaviour: the control that opened the mode is the control that closes it, so a
  second tap is never a surprise. Tapping Done clears the selection, since
  leaving the mode with a selection still held would mean nothing.

  The caller hides this when there are no swings. It is not disabled, it is
  absent, because a bulk delete control on an empty list is an offer that cannot
  be taken.
*/
struct SelectionTrashButton: View {
    @Binding var selectionMode: Bool
    @Binding var selectedIds: Set<String>

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                if selectionMode {
                    selectionMode = false
                    selectedIds.removeAll()
                } else {
                    selectedIds.removeAll()
                    selectionMode = true
                }
            }
        } label: {
            Group {
                if selectionMode {
                    Text("Done")
                        .font(.body(TypeScale.small))
                        .foregroundStyle(Tok.citrus)
                } else {
                    Image(systemName: "trash")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Tok.bone2)
                }
            }
            .frame(minWidth: 34, minHeight: 34)
            .padding(.horizontal, selectionMode ? 10 : 0)
            .background(Capsule().fill(Tok.turf800))
            .overlay(Capsule().strokeBorder(selectionMode ? Tok.citrusDim : Tok.line, lineWidth: 1))
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(selectionMode ? "Finish selecting" : "Select swings to delete")
    }
}

// MARK: - Bottom bar

/*
  The count, the destructive action, and the way out.

  Delete is disabled rather than hidden while nothing is ticked, so the bar does
  not change shape as the selection grows, and the count carries the state
  instead. The wording says the number back to the golfer at every step, on the
  bar and again in the alert, because this is the one action in the app that
  cannot be undone.
*/
struct BulkDeleteBar: View {
    let count: Int
    let onDelete: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: Tok.s3) {
            Text(count == 1 ? "1 selected" : "\(count) selected")
                .font(.data(TypeScale.small))
                .foregroundStyle(count == 0 ? Tok.bone3 : Tok.bone)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.2), value: count)

            Spacer(minLength: 0)

            Button(action: onCancel) {
                Text("Cancel")
                    .font(.body(TypeScale.small))
                    .padding(.vertical, 10)
                    .padding(.horizontal, 18)
                    .foregroundStyle(Tok.bone)
                    .overlay { Capsule().strokeBorder(Tok.lineStrong, lineWidth: 1) }
            }
            .buttonStyle(PressScale())

            Button(action: onDelete) {
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .medium))
                    Text("Delete")
                        .font(.body(TypeScale.small))
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 18)
                .foregroundStyle(count == 0 ? Tok.bone3 : Tok.rust)
                .overlay {
                    Capsule().strokeBorder(
                        (count == 0 ? Tok.line : Tok.rust.opacity(0.6)),
                        lineWidth: 1
                    )
                }
            }
            .buttonStyle(PressScale())
            .disabled(count == 0)
        }
        .padding(.horizontal, Tok.s4)
        .padding(.vertical, Tok.s3)
        .background {
            Rectangle()
                .fill(Tok.turf900.opacity(0.94))
                .overlay(alignment: .top) {
                    Rectangle().fill(Tok.line).frame(height: 1)
                }
                .ignoresSafeArea(edges: .bottom)
        }
    }
}