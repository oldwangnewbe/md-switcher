namespace MDSwitcher;

internal sealed class CardThumbnails(Action refresh) : IDisposable
{
    private readonly Dictionary<string, Bitmap?> images = new(StringComparer.OrdinalIgnoreCase);
    private readonly Queue<string> cached = new();
    private string[] visible = [];
    private int size;
    private bool loading;
    private bool disposed;

    public Bitmap? Get(string path) => images.GetValueOrDefault(path);

    public void Request(IEnumerable<string> paths, int pixels)
    {
        if (disposed) return;
        if (size != pixels)
        {
            Clear();
            size = pixels;
        }
        visible = paths.Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        if (!loading) _ = LoadVisibleAsync();
    }

    private async Task LoadVisibleAsync()
    {
        loading = true;
        try
        {
            while (!disposed)
            {
                // Keep one small batch in flight. After a fast scroll the next batch uses the new viewport.
                var missing = visible.Where(path => !images.ContainsKey(path)).Take(8).ToArray();
                if (missing.Length == 0) break;
                var pixels = size;
                var batch = await Task.Run(() => missing.Select(path => Read(path, pixels)).ToArray());
                if (disposed || pixels != size)
                {
                    foreach (var bitmap in batch) bitmap?.Dispose();
                    continue;
                }
                for (var i = 0; i < missing.Length; i++)
                {
                    if (images.Count >= 240 && images.Remove(cached.Dequeue(), out var evicted)) evicted?.Dispose();
                    images.Add(missing[i], batch[i]);
                    cached.Enqueue(missing[i]);
                }
                if (missing.Any(path => visible.Contains(path, StringComparer.OrdinalIgnoreCase))) refresh();
            }
        }
        finally { loading = false; }
    }

    internal static Bitmap? Read(string path, int? maxSize = null)
    {
        try
        {
            using var stream = File.OpenRead(path);
            using var image = Image.FromStream(stream);
            var maxDimension = Math.Max(image.Width, image.Height);
            var scale = maxSize is int limit ? Math.Min(1, (double)limit / maxDimension) : 1;
            return new Bitmap(image, Math.Max(1, (int)(image.Width * scale)), Math.Max(1, (int)(image.Height * scale)));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException
            or System.Runtime.InteropServices.ExternalException or OutOfMemoryException)
        {
            // GDI+ can report an invalid or unsupported image as OutOfMemoryException.
            return null;
        }
    }

    private void Clear()
    {
        foreach (var bitmap in images.Values) bitmap?.Dispose();
        images.Clear();
        cached.Clear();
    }

    public void Dispose()
    {
        disposed = true;
        Clear();
    }
}
