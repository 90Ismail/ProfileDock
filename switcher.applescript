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
    tell application "Google Chrome" to activate
    tell application "System Events"
        tell process "Google Chrome"
            set frontmost to true
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
            click menu item targetIndex of profileMenu
        end tell
    end tell
    delay 0.4
    tell application "Google Chrome"
        set fallbackID to id of front window
        set windowIDs to id of every window whose mode is "normal"
    end tell
    set matchingIDs to {}
    set choices to {}
    repeat with windowID in windowIDs
        set wasMinimized to false
        try
            tell application "Google Chrome"
                set candidate to window id (contents of windowID)
                set wasMinimized to minimized of candidate
                set minimized of candidate to false
                set index of candidate to 1
            end tell
            delay 0.25
            tell application "System Events" to tell process "Google Chrome"
                set profileMenu to menu 1 of menu bar item "Profiles" of menu bar 1
                set markValue to value of attribute "AXMenuItemMarkChar" of menu item targetIndex of profileMenu
            end tell
            if markValue is not missing value and markValue is not "" then
                tell application "Google Chrome"
                    set windowTitle to name of candidate
                    set tabCount to count tabs of candidate
                end tell
                set end of matchingIDs to contents of windowID
                set end of choices to ((count matchingIDs) as text) & ". " & windowTitle & " (" & tabCount & " tabs)"
            end if
            tell application "Google Chrome" to set minimized of candidate to wasMinimized
        on error errorMessage number errorNumber
            try
                tell application "Google Chrome" to set minimized of window id (contents of windowID) to wasMinimized
            end try
            my focusWindow(fallbackID)
            error errorMessage number errorNumber
        end try
    end repeat
    my focusWindow(fallbackID)
    if (count matchingIDs) is 0 then error "Could not identify this profile's windows. Chrome's menu may have changed."
    if (count matchingIDs) is 1 then
        my focusWindow(item 1 of matchingIDs)
    else
        activate
        set selectedChoice to choose from list choices with title "ProfileDock — " & profileName with prompt ((count matchingIDs) as text) & " windows open. Choose a window:" default items {item 1 of choices} OK button name "Switch" cancel button name "Cancel"
        if selectedChoice is false then return
        repeat with i from 1 to count choices
            if item i of choices is item 1 of selectedChoice then
                my focusWindow(item i of matchingIDs)
                exit repeat
            end if
        end repeat
    end if
end switchProfile

on focusWindow(windowID)
    tell application "Google Chrome"
        set minimized of window id windowID to false
        set index of window id windowID to 1
        activate
    end tell
end focusWindow
