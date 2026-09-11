on run
    set appPath to POSIX path of (path to me)
    set folderPath to do shell script "/usr/bin/dirname " & quoted form of (text 1 thru -2 of appPath)
    set helperPath to folderPath & "/ProfileDock Helper.app"
    set configPath to appPath & "Contents/Resources/profile.txt"
    do shell script "/usr/bin/open -a " & quoted form of helperPath & " " & quoted form of configPath
end run
