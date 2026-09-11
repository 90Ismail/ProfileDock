-- Read profile membership from Chrome's own checked Profiles menu item.
-- Chrome AppleScript does not expose a profile property on windows.
on open inputFiles
    repeat with inputFile in inputFiles
        try
            set profileName to read inputFile as «class utf8»
            if profileName is "" then error "The shortcut profile label is empty."
            set profileName to paragraph 1 of profileName
            my switchProfile(profileName, 0, {})
        on error errorMessage number errorNumber
            if errorNumber is not -128 then
                if errorNumber is -25211 or errorNumber is -1743 or errorNumber is 1002 then set errorMessage to errorMessage & return & return & "Enable the helper in System Settings → Privacy & Security → Accessibility and allow its Automation access to Chrome and System Events."
                display dialog errorMessage buttons {"OK"} default button "OK" with title "ProfileDock"
            end if
        end try
    end repeat
end open

on switchProfile(profileName, configuredIndex, expectedNames)
    if not application "Google Chrome" is running then tell application "Google Chrome" to activate
    tell application "System Events"
        tell process "Google Chrome"
            repeat 50 times
                if exists menu bar item "Profiles" of menu bar 1 then exit repeat
                delay 0.1
            end repeat
            set profileMenu to menu 1 of menu bar item "Profiles" of menu bar 1
            set menuNames to name of every menu item of profileMenu
            if configuredIndex > 0 then
                -- Only used by a private adapter for legacy, duplicate profile names.
                if items 1 thru (count expectedNames) of menuNames is not expectedNames then error "Chrome profile names or ordering changed. Update the private adapter."
                set targetIndex to configuredIndex
            else
                set targetIndex to 0
                repeat with i from 1 to count menuNames
                    if item i of menuNames is profileName then
                        if targetIndex > 0 then error "Duplicate Chrome profile name. Rename profiles to distinct names first."
                        set targetIndex to i
                    end if
                end repeat
                if targetIndex is 0 then error "Chrome profile not found: " & profileName
            end if
        end tell
    end tell
    tell application "Google Chrome"
        set windowIDs to id of every window whose mode is "normal"
        set observedID to ""
        if (count windows) > 0 then set observedID to (id of front window) as text
    end tell
    tell application "System Events" to set chromePID to unix id of process "Google Chrome"
    set oldDelimiters to AppleScript's text item delimiters
    set AppleScript's text item delimiters to tab
    set headerKey to (chromePID as text) & tab & (menuNames as text)
    set AppleScript's text item delimiters to oldDelimiters
    set {cacheIDs, cacheOwners} to my readCache(headerKey)
    set observedOwner to 0
    tell application "System Events" to tell process "Google Chrome"
        set marks to value of attribute "AXMenuItemMarkChar" of every menu item of profileMenu
    end tell
    repeat with i from 1 to count marks
        if item i of marks is not missing value and item i of marks is not "" then
            set observedOwner to i
            exit repeat
        end if
    end repeat
    set nextIDs to {}
    set nextOwners to {}
    set matchingIDs to {}
    set choices to {}
    repeat with windowID in windowIDs
        set idText to (contents of windowID) as text
        set ownerIndex to 0
        repeat with i from 1 to count cacheIDs
            if item i of cacheIDs is idText then
                set ownerIndex to item i of cacheOwners
                exit repeat
            end if
        end repeat
        if idText is observedID and observedOwner > 0 then set ownerIndex to observedOwner
        if ownerIndex > 0 then
            set end of nextIDs to idText
            set end of nextOwners to ownerIndex
        end if
        if ownerIndex is targetIndex then
            tell application "Google Chrome"
                set candidate to window id (contents of windowID)
                set windowTitle to name of candidate
                set tabCount to count tabs of candidate
            end tell
            set end of matchingIDs to contents of windowID
            set end of choices to windowTitle & tab & tabCount
        end if
    end repeat
    my writeCache(headerKey, nextIDs, nextOwners)
    if (count matchingIDs) is 0 then
        -- No known window: let Chrome open/select this profile once, never scan.
        tell application "Google Chrome" to activate
        tell application "System Events" to tell process "Google Chrome" to click menu item targetIndex of menu 1 of menu bar item "Profiles" of menu bar 1
        delay 0.3
        tell application "Google Chrome" to set newID to (id of front window) as text
        if nextIDs does not contain newID then
            set end of nextIDs to newID
            set end of nextOwners to targetIndex
            my writeCache(headerKey, nextIDs, nextOwners)
        end if
        return
    end if
    if (count matchingIDs) is 1 then
        my focusWindow(item 1 of matchingIDs)
    else
        set menuPath to (POSIX path of (path to me)) & "Contents/Resources/ProfileDockMenu"
        set menuCommand to quoted form of menuPath & " " & quoted form of profileName
        repeat with choiceTitle in choices
            set menuCommand to menuCommand & " " & quoted form of (contents of choiceTitle)
        end repeat
        set selectedIndex to (do shell script menuCommand) as integer
        if selectedIndex > 0 and selectedIndex ≤ (count matchingIDs) then
            my focusWindow(item selectedIndex of matchingIDs)
        else if selectedIndex < 0 and -selectedIndex ≤ (count matchingIDs) then
            tell application "Google Chrome" to close window id (item (-selectedIndex) of matchingIDs)
            my switchProfile(profileName, configuredIndex, expectedNames)
        end if
    end if
end switchProfile

on focusWindow(windowID)
    tell application "Google Chrome"
        set minimized of window id windowID to false
        set index of window id windowID to 1
        activate
    end tell
end focusWindow

on cachePath()
    set folderPath to (POSIX path of (path to application support from user domain)) & "ProfileDock"
    try
        set existingFolder to POSIX file folderPath as alias
    on error
        do shell script "/bin/mkdir -p " & quoted form of folderPath
    end try
    return folderPath & "/window-membership.txt"
end cachePath

on readCache(headerKey)
    set cacheIDs to {}
    set cacheOwners to {}
    try
        set cacheText to read POSIX file (my cachePath()) as «class utf8»
        set cacheLines to paragraphs of cacheText
        if item 1 of cacheLines is not headerKey then return {cacheIDs, cacheOwners}
        repeat with i from 2 to count cacheLines
            set lineText to item i of cacheLines
            if lineText is not "" then
                set oldDelimiters to AppleScript's text item delimiters
                set AppleScript's text item delimiters to tab
                set fields to text items of lineText
                set AppleScript's text item delimiters to oldDelimiters
                set end of cacheIDs to item 1 of fields
                set end of cacheOwners to (item 2 of fields) as integer
            end if
        end repeat
    on error
        return {{}, {}}
    end try
    return {cacheIDs, cacheOwners}
end readCache

on writeCache(headerKey, cacheIDs, cacheOwners)
    set cacheText to headerKey & linefeed
    repeat with i from 1 to count cacheIDs
        set cacheText to cacheText & item i of cacheIDs & tab & item i of cacheOwners & linefeed
    end repeat
    set fileHandle to open for access POSIX file (my cachePath()) with write permission
    try
        set eof fileHandle to 0
        write cacheText to fileHandle as «class utf8»
        close access fileHandle
    on error msg number num
        close access fileHandle
        error msg number num
    end try
end writeCache
