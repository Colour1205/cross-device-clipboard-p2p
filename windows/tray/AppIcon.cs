namespace ClipboardTray;

// The ClipLink icon (windows/ClipLink.ico, embedded by the csproj). The
// csproj's ApplicationIcon only brands the .exe file in Explorer; the tray
// icon and each window's title-bar/taskbar icon have to be set from code.
public static class AppIcon
{
    // Every size in the .ico - for Form.Icon, which picks its own large
    // and small sizes out of it.
    public static Icon Window { get; } = Load(null);

    // The frame closest to the notification area's icon size, so the tray
    // gets the hand-sized 16/20/24px frame instead of a downscaled large one.
    public static Icon Tray { get; } = Load(SystemInformation.SmallIconSize);

    private static Icon Load(Size? size)
    {
        using var stream = typeof(AppIcon).Assembly.GetManifestResourceStream("ClipLink.ico")
            ?? throw new InvalidOperationException("ClipLink.ico is not embedded - see ClipboardTray.csproj");
        return size is Size s ? new Icon(stream, s) : new Icon(stream);
    }
}
