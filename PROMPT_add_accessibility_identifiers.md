# Implementation Prompt: Add Accessibility Identifiers to MLM for Shotty Automation

## Context

You are planning an implementation to add accessibility identifiers to the Music Library Manager (MLM) macOS app. This is required to enable reliable UI automation via the shotty tool.

**Background:**
- MLM is a SwiftUI macOS app at `/Users/olli/schenanigans/MusicLibraryManager/macos-app/`
- Shotty is a UI automation helper that drives macOS/iOS apps via accessibility APIs
- Shotty's symbolic targeting (the reliable method) requires elements to have `.accessibilityIdentifier()` modifiers
- Currently, MLM has NO accessibility identifiers, so shotty cannot use symbolic targeting
- Coordinate-based targeting is fragile and unreliable (taps execute but don't hit interactive elements)
- Background window automation is broken for type actions (macOS CGEvent limitation)

**Full bug report:** `/Users/olli/schenanigans/MusicLibraryManager/.shotty/BUG_REPORT_shotty_mlm_20260822.md`

## Goal

Add `.accessibilityIdentifier()` modifiers to all interactive elements in MLM's SwiftUI views so that shotty can reliably automate the app using symbolic targeting.

## What You Need to Do

### 1. Identify All Interactive Elements

Search through all SwiftUI view files in `/Users/olli/schenanigans/MusicLibraryManager/macos-app/Sources/` and identify:

- **TextFields** — search fields, input fields, text editors
- **Buttons** — action buttons, toolbar buttons, sidebar buttons
- **Toggles/Switches** — boolean controls
- **Pickers/Dropdowns** — selection controls
- **Sliders** — range controls
- **List items** — tappable list rows (if they have actions)
- **Navigation links** — sidebar navigation items
- **Menu items** — if custom menus are used

**Important:** Only add identifiers to elements that the user (or an automation tool) would interact with. Don't add identifiers to static labels or decorative elements.

### 2. Choose Meaningful Identifier Names

Use a consistent naming convention:

- **Lowercase with underscores:** `search_field`, `playlists_button`, `settings_toggle`
- **Descriptive but concise:** The name should clearly indicate the element's purpose
- **Prefix by section (optional):** If there are multiple elements with similar names in different sections, use prefixes like `sidebar_playlists_button`, `toolbar_search_field`

**Examples of good names:**
- `search_field` — for the main search TextField
- `playlists_button` — for the Playlists sidebar button
- `settings_button` — for the Settings button
- `import_button` — for an Import action button
- `track_list` — for the main track list view
- `volume_slider` — for a volume control

**Examples of bad names:**
- `button1`, `button2` — not descriptive
- `Search` — too generic, might conflict with other search elements
- `main_view_search_textfield_input_field` — too verbose

### 3. Add the Modifiers

For each interactive element, add `.accessibilityIdentifier("name")` as a modifier.

**Before:**
```swift
TextField("Search library...", text: $searchText)
    .textFieldStyle(.roundedBorder)
    .frame(width: 200)
```

**After:**
```swift
TextField("Search library...", text: $searchText)
    .textFieldStyle(.roundedBorder)
    .frame(width: 200)
    .accessibilityIdentifier("search_field")
```

**For buttons:**

**Before:**
```swift
Button("Playlists") {
    selectedSection = .playlists
}
```

**After:**
```swift
Button("Playlists") {
    selectedSection = .playlists
}
.accessibilityIdentifier("playlists_button")
```

**For complex views (e.g., custom list rows):**

If you have a custom view that represents a tappable item, add the identifier to the root view:

```swift
struct TrackRow: View {
    let track: Track
    
    var body: some View {
        HStack {
            Text(track.title)
            Text(track.artist)
        }
        .contentShape(Rectangle()) // Makes the entire row tappable
        .onTapGesture {
            // handle tap
        }
        .accessibilityIdentifier("track_row_\(track.id)") // Dynamic identifier
    }
}
```

**Note:** For dynamic content (like list items), you can use dynamic identifiers that include the item's ID. This allows shotty to target specific items. However, be aware that dynamic identifiers change when the data changes, so they're less stable than static identifiers.

### 4. Priority Elements

Focus on these elements first (highest impact for automation):

1. **Search field** — The main search TextField (probably in the toolbar or top of the library view)
2. **Sidebar navigation** — Library, Playlists, Liked, Local Likes, Folders, Sync, Sources, Review, Discover, Settings
3. **Action buttons** — Import, Export, Delete, Edit, etc.
4. **Playback controls** — Play, Pause, Next, Previous, Volume (if present)
5. **Filter/sort controls** — Any dropdowns or pickers for filtering the library

### 5. Testing

After adding the identifiers:

1. **Build the app:**
   ```bash
   cd /Users/olli/schenanigans/MusicLibraryManager/macos-app
   swift build
   ```

2. **Verify identifiers are exposed:**
   ```bash
   # Launch the app
   open /Users/olli/schenanigans/MusicLibraryManager/macos-app/.build/MLM.app
   
   # Attach shotty
   cd /Users/olli/schenanigans/shotty
   .build/debug/shotty attach pid:<MLM_PID> --project /Users/olli/schenanigans/MusicLibraryManager
   
   # List elements
   .build/debug/shotty elements --session <SESSION_ID> --project /Users/olli/schenanigans/MusicLibraryManager
   ```
   
   You should see a list of elements with their identifiers and `live: true` for visible elements.

3. **Test symbolic targeting:**
   ```bash
   # Try tapping a sidebar item
   .build/debug/shotty run '{"session":"<SESSION_ID>","actions":[{"tap":"playlists_button"}]}' --project /Users/olli/schenanigans/MusicLibraryManager
   
   # Try typing in the search field
   .build/debug/shotty run '{"session":"<SESSION_ID>","actions":[{"type":"2Pac","into":"search_field"}]}' --project /Users/olli/schenanigans/MusicLibraryManager
   ```

### 6. Documentation

Add a comment at the top of each modified file explaining that accessibility identifiers are used for UI automation:

```swift
// MARK: - Accessibility Identifiers
// This view uses .accessibilityIdentifier() modifiers to enable UI automation via shotty.
// See: /Users/olli/schenanigans/MusicLibraryManager/.shotty/BUG_REPORT_shotty_mlm_20260822.md
```

## File Locations

**Main source directory:**
```
/Users/olli/schenanigans/MusicLibraryManager/macos-app/Sources/
```

**Likely files to modify (you'll need to explore the actual structure):**
- `Views/LibraryView.swift` — main library view with track list
- `Views/SidebarView.swift` — sidebar navigation
- `Views/SearchField.swift` or similar — search field component
- `Views/ToolbarView.swift` — toolbar with action buttons
- `Views/TrackRow.swift` or similar — individual track row view
- `Views/SettingsView.swift` — settings/preferences view
- `Views/PlaylistView.swift` — playlist view
- `App.swift` or `MLMApp.swift` — main app entry point

**Build output:**
```
/Users/olli/schenanigans/MusicLibraryManager/macos-app/.build/MLM.app
```

**Shotty tool:**
```
/Users/olli/schenanigans/shotty/.build/debug/shotty
```

**Bug report (for reference):**
```
/Users/olli/schenanigans/MusicLibraryManager/.shotty/BUG_REPORT_shotty_mlm_20260822.md
```

## Expected Outcome

After this implementation:

1. `shotty elements` should return a list of 20-50 elements (depending on how many interactive elements MLM has)
2. Symbolic targeting should work: `{"tap":"search_field"}` should focus the search field
3. Typing should work: `{"type":"2Pac","into":"search_field"}` should enter text and trigger the search
4. Navigation should work: `{"tap":"playlists_button"}` should switch to the playlists view
5. The app should be automatable end-to-end via shotty

## Constraints

- **Don't break existing functionality** — Adding accessibility identifiers should not change the app's behavior
- **Keep identifiers stable** — Avoid dynamic identifiers unless necessary (they break when data changes)
- **Don't over-identify** — Only add identifiers to interactive elements, not static labels
- **Follow SwiftUI best practices** — Place `.accessibilityIdentifier()` at the end of the modifier chain

## Questions to Consider

As you plan the implementation, consider:

1. **How many interactive elements does MLM have?** Scan the codebase to get a rough count.
2. **Are there any custom controls** that might need special handling (e.g., custom buttons, custom list rows)?
3. **Should you add identifiers to menu bar items** (if MLM has a custom menu bar)?
4. **Are there any modal sheets or popovers** that need identifiers?
5. **Should you create a centralized list of identifier constants** (e.g., `enum AccessibilityID { static let searchField = "search_field" }`) to avoid typos?

## Deliverables

Your plan should include:

1. **List of files to modify** — with absolute paths
2. **List of identifiers to add** — with the element type and location in each file
3. **Code examples** — showing the before/after for each type of element
4. **Testing strategy** — how to verify the identifiers work with shotty
5. **Estimated effort** — rough estimate of how many files and elements need modification

## References

- **Shotty documentation:** `/Users/olli/schenanigans/shotty/README.md`
- **Shotty AGENTS.md (platform quirks):** `/Users/olli/schenanigans/shotty/AGENTS.md`
- **MLM bug report:** `/Users/olli/schenanigans/MusicLibraryManager/.shotty/BUG_REPORT_shotty_mlm_20260822.md`
- **SwiftUI accessibility documentation:** https://developer.apple.com/documentation/swiftui/view/accessibilityidentifier(_:)

## Next Steps

1. **Explore the MLM codebase** — Understand the view hierarchy and identify all interactive elements
2. **Create a list of identifiers** — Plan which identifiers to add and where
3. **Implement the changes** — Add `.accessibilityIdentifier()` modifiers to all interactive elements
4. **Test with shotty** — Verify that symbolic targeting works
5. **Iterate** — Add more identifiers if needed based on testing

Good luck! This implementation will make MLM fully automatable via shotty, enabling AI-driven testing and automation workflows.
