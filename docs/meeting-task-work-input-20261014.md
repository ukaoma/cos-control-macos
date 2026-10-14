# Meeting task creation and Work editor responsiveness

Local matched candidate: Control 0.5.295/build 348, server 6.73.5. Public distribution remains a separate action.

Saved meeting details offer Create task and Link to existing task. Creation uses the canonical task writer to persist the task and exact saved meeting reference in one locked write. Retries reuse the same linked task. A collision with unrelated or closed work is explicit. Open task in Work follows the persisted stable identity. Meeting files are resolved through the existing meeting context store. No provider assignment or completion is implied.

Work chat retains its independent rich composer, idle journal writes, and send/navigation flush. Context to send now observes only an independent draft object; session lists, file manifests and timeline do not rebuild on each key. Add task, replies, and review title editors use the same isolation. Session search uses the existing coalesced search control. Native control typography and action layouts are retained.

Automated coverage: authenticated request validation, exact saved meeting resolution, canonical one-write capture, duplicate/collision handling, renamed stable identity, model/helper payload and failure propagation, native context edit/layout timing and zero burst writes/redraws, idle/navigation/reload durability, and existing rich chat/connection/orchestration regressions. Disposable fixtures only; no production task or session was created. Physical keyboard-to-screen responsiveness remains a manual check after install.
