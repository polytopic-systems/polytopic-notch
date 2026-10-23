# Live lists

A list in the pill that follows its newest item and holds still while the user works with it.

## Overview

Newest first, rows with buttons (an event log):

```swift
struct LogEvent: Identifiable, Equatable {
    let id: Int
    let text: String
}

@MainActor
@Observable
final class EventLog {
    let feed = NotchLiveFeed<LogEvent>(edge: .top)    // newest first
    private var events: [LogEvent] = []
    private var nextID = 0

    func add(_ text: String) {
        events.insert(LogEvent(id: nextID, text: text), at: 0)
        nextID += 1
        events = Array(events.prefix(50))
        feed.publish(events)                          // the whole list, in display order
    }
}

struct EventList: View {
    let log: EventLog

    var body: some View {
        NotchLiveList(log.feed, spacing: 2) { event in
            HStack {
                Text(event.text).lineLimit(1)
                Spacer()
                Button("Dismiss") {}
            }
            .notchLiveAction()                        // pointing at a row with buttons holds the list still
        }
        .frame(height: 150)
        .padding(.horizontal, 16)
    }
}
```

Newest last, text only (a transcript):

```swift
struct TranscriptView: View {
    let feed: NotchLiveFeed<Segment>                  // NotchLiveFeed(edge: .bottom): newest last

    var body: some View {
        NotchLiveList(feed, spacing: 4, showsIndicators: true) { segment in
            Text(segment.text)                        // not marked: pointing at text doesn't hold the list
        }
    }
}
```

Why: a list that just shows the latest moves under the user. A new event pushes the row under the pointer, and its
buttons, down; a click lands on the wrong row.

## When it holds

| Reason | When |
|---|---|
| `.pointer` | the pointer is on an element marked `.notchLiveAction()` |
| `.menu` | a menu from the pill is open (``NotchMenuButton``) |
| `.reading` | the user scrolled away from the newest item |
| `.app("…")` | you hold it |

While held with something new, an "N new" capsule sits at the live edge; a click on it goes back to live at once.

```swift
@MainActor
func showResult(in feed: NotchLiveFeed<LogEvent>) async {
    feed.hold(.app("result"))                         // a row shows the result of a click: don't move it
    try? await Task.sleep(for: .seconds(3))
    feed.release(.app("result"))
}
```

## When it follows again

- Pointer, menu and app gone, at the live edge: after 1.2 s (`actionGrace`), so moving from one row's buttons to the
  next doesn't jump the list in between.
- Scrolled away: 5 s after the last scroll (`readingIdle`), then it scrolls back. Each scroll restarts the wait.
- Scrolled back to the edge by hand, or the capsule clicked: at once.
- The pill closing resets the feed; call `feed.reset()` yourself when a tab changes.

```swift
feed.timing = .init(actionGrace: .seconds(1), readingIdle: .seconds(8))
```

## Notes

- Publish the whole current list each time, in display order; items are matched by `id`.
- Nothing ticks: one sleeping task only while a deadline is pending and the list shows.
- `NotchLiveFollow` is the algorithm as a pure value with the clock passed in, for a list you draw yourself or a test.
- Scrolling back respects Reduce Motion.
