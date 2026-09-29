# Release Notes

## 1.1.6 — 2026-09-29

- Clipboard recording now shows a paused badge in the main panel and history list, with a hint for resuming it.
- Manual clipboard sync now uses a passphrase already saved in Keychain without asking you to enter it again.
- The clipboard history item limit has moved from Filters to the management section, where retention settings belong.
- Clipboard image text and QR recognition now have a privacy switch. Turning it off stops recognition and removes saved recognition results while keeping the images.
- Clipboard management now shows the actual space used by the database, backup, and attachments, and offers immediate cleanup and database compaction.
- Smooth scrolling settings now distinguish an active listener, missing Accessibility permission, and a listener that failed to start.
- Clipboard snippets are now encrypted with AES-GCM on disk. Existing plain JSON files are migrated when snippets are next used.
- Equalizer changes now keep only the current and previous configuration, preventing memory growth without releasing data still read by audio callbacks.
- System resource alert cooldowns now survive app restarts, avoiding repeated alerts for the same condition.
- Resource percentages now use one scale across settings and the menu bar. History bars support arrow keys, and per-core values are accessible to VoiceOver.
- `menutools://` links can now trigger scenes and quick actions, including from Raycast and Shortcuts.
- Quick-action link names now parse acronyms correctly: `flushDNS` resolves as `flush-dns`.
- Settings pages now use consistent success, failure, and information banners so errors are not mistaken for successful actions.
- The screenshot editor now supports keyboard shortcuts for undo, copying recognized text, clearing annotations, saving, and cancelling, with accessibility labels on icon buttons.
- Screenshot history can now search file names, expand beyond the first eight entries, and show capture times. Clearing the list requires confirmation and does not delete image files.
- Screenshot crops, rotations, cleared annotations, and new annotations now support undo and redo, with up to 30 history steps.
- Smooth scrolling now leaves scrolling in MenuTools’ own visible panels untouched.
- Per-app audio now warns after five seconds of unexpected silence that protected audio may be involved; it does not change the audio route. This behavior still needs validation with protected media.
- Finder context menus now follow the language selected inside MenuTools, including changes made while the app is running.
- Finder context menus cache clipboard image results and terminal availability, and limit image decoding to reduce delays with large screenshots or multiple selections.
- Plugin Center now shows dependencies and dependents. Automation declares its actual dependencies so disabling a required plugin cannot silently break scenes.
- Plugin Center now explains that disabling Finder commands does not uninstall the system extension, and shows where to remove it.
- Battery health alerts now warn below 80% health or when macOS recommends service, with a seven-day cooldown that survives restarts. Macs without a battery skip these alerts.
- Settings now support global search with ⌘F, keyboard navigation in the sidebar, and improved accessibility labels.
- Clipboard history now offers separate retention periods for text, images, links, files, rich text, and PDFs.
- The Finder extension and the main app now report the same 1.1.6 version.
- Finder context-menu diagnostics now distinguish Accessibility permission from Automation permission and report only the actual configuration directory’s writability.
