namespace ClipboardDaemon.Storage;

public record ClipboardEntry(string Content, string Type, string DeviceId, DateTime Timestamp, string? Signature = null)
{
    
}