# Experimental: Live TV

Watch a Jellyfin server's live channels on Apple TV: a guide, a player, and a Home shelf.
It works well against one setup and is unproven beyond it, which is why it is here and
not in the main docs.

This folder holds one page per feature that ships before it is finished. A page says what
works, what does not, and what is left. When the feature graduates, fold the page into
the permanent docs and delete it.

**Status**: experimental, tvOS only. Vision Pro shows nothing for it.
**Appears when**: the signed-in server has a Live TV library. There is no setting.
**Tested against**: Jellyfin 10.11.11 with one M3U tuner and XMLTV guide (ErsatzTV), five
channels, on an Apple TV 4K and the tvOS simulator.

## What it does

| Where | What |
| --- | --- |
| Sidebar | A Live TV entry after the library tabs. |
| Guide | Channels down the side, twelve hours across from the current half hour. A header describes the focused programme. Select plays the channel. |
| Player | The system player with a LIVE badge, the programme as title, and a Guide tab in the swipe-down panel for changing channel. |
| Home | An On Air Now shelf between Recently Added and the genre shelves. Select plays the channel. |

How the app talks to the server is in
[JELLYFIN_INTEGRATION.md](../JELLYFIN_INTEGRATION.md#live-tv---experimental-tvos-only).
Why the player is separate is in the [ARCHITECTURE.md](../ARCHITECTURE.md#decision-log)
decision log.

## What has been checked

| Claim | Venue |
| --- | --- |
| Hours of play with no hang and one rebuffer. Library playback and Home focus unchanged. | Device, by the owner |
| Guide layout, fades and the player's titles look right in the Standard theme. | Device, by the owner |
| Guide, playback, channel change, Back, and the Home shelf complete as flows. | Simulator check |
| With no Live TV on the server, there is no sidebar entry and no shelf, and Home's focus order is unchanged. | Simulator check |
| The tuner is released on Back, on a channel change and on a player failure. | Server log |

## Known limits

**Will bite a real user**

1. **A frozen or ended stream is not noticed.** Only an outright player failure shows an
   error. There is no stall watchdog and no reconnecting state.
2. **A server with Live TV and no other library** shows Home's "Nothing Here".
3. **Only small guides are proven.** Every check had five channels. Rows are not built
   lazily, so load time and scrolling with hundreds of channels are unknown.
4. **Other tuner types are untested.** HDHomeRun, and M3U tuners with fMP4 segments
   allowed, may behave differently from what the stream rules assume.
5. **Playback starts 30 seconds behind live.** That covers a tuner that delivers in
   bursts. Its effect on a tuner that is truly real time is untested.

**Rough edges**

1. Portrait poster art is cropped to fit 16:9 slots.
2. The Guide tab's second caption line is cut off.
3. Short filler clips show as tiny guide cells. A fix is proposed in the spike ledger and
   postponed.
4. The live timeline can be scrubbed back, and whether that is wanted is undecided.
5. Themes other than Standard have not been looked at on a device.

## Graduating

Live TV leaves this folder when the first list above is closed or consciously accepted,
and it has been run against a second tuner type and a guide of a hundred channels or more.

The experiments behind every claim here, with raw output, are in
[spikes/live-tv.md](../spikes/live-tv.md).
