using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace MDSwitcher;

internal sealed record ResourceVolume(string Mount, string FileSystem, long CloneAlignment)
{
    private const uint SupportsBlockRefcounting = 0x08000000;
    private const uint DuplicateExtentsToFile = 0x00098344;

    public static ResourceVolume Read(string directory)
    {
        if (!OperatingSystem.IsWindows()) return new("", "未知", 0);
        var mount = new StringBuilder(32768);
        var format = new StringBuilder(256);
        if (!GetVolumePathName(directory, mount, (uint)mount.Capacity) ||
            !GetVolumeInformation(mount.ToString(), IntPtr.Zero, 0, out _, out _, out var flags, format, (uint)format.Capacity))
            throw new IOException("无法确认游戏资源所在磁盘。", new Win32Exception(Marshal.GetLastWin32Error()));
        var root = mount.ToString();
        var fileSystem = format.ToString();
        if ((flags & SupportsBlockRefcounting) == 0) return new(root, fileSystem, 0);
        if (!GetDiskFreeSpace(root, out var sectorsPerCluster, out var bytesPerSector, out _, out _))
            throw new IOException("无法读取磁盘的块大小。", new Win32Exception(Marshal.GetLastWin32Error()));
        return new(root, fileSystem, (long)sectorsPerCluster * bytesPerSector);
    }

    public bool CanCloneTo(ResourceVolume destination) => CloneAlignment > 0 && CloneAlignment == destination.CloneAlignment
        && Mount.Equals(destination.Mount, StringComparison.OrdinalIgnoreCase);

    public bool CanHardLinkTo(ResourceVolume destination) => FileSystem.Equals("NTFS", StringComparison.OrdinalIgnoreCase)
        && FileSystem.Equals(destination.FileSystem, StringComparison.OrdinalIgnoreCase)
        && Mount.Equals(destination.Mount, StringComparison.OrdinalIgnoreCase);

    public static void HardLink(string source, string destination)
    {
        if (CreateHardLink(destination, source, IntPtr.Zero)) return;
        var error = Marshal.GetLastWin32Error();
        throw new IOException($"无法创建资源硬链接（Windows 错误 {error}）。", new Win32Exception(error));
    }

    public long CloneAlignedBlocks(FileStream source, FileStream destination, long size, Action checkProgress)
    {
        var length = size - size % CloneAlignment;
        if (length == 0) return 0;
        destination.SetLength(length);
        // ReFS requires each request to be smaller than 4 GiB and aligned to the volume cluster size.
        var maxChunk = 1024L * 1024 * 1024 / CloneAlignment * CloneAlignment;
        var sourceHandle = source.SafeFileHandle;
        var destinationHandle = destination.SafeFileHandle;
        for (long offset = 0; offset < length;)
        {
            var chunk = Math.Min(length - offset, maxChunk);
            var request = new CloneRequest { Source = sourceHandle.DangerousGetHandle(), SourceOffset = offset,
                TargetOffset = offset, ByteCount = chunk };
            if (!DeviceIoControl(destinationHandle, DuplicateExtentsToFile, ref request,
                (uint)Marshal.SizeOf<CloneRequest>(), IntPtr.Zero, 0, out _, IntPtr.Zero))
            {
                var error = Marshal.GetLastWin32Error();
                throw new IOException($"磁盘未能共享资源块（Windows 错误 {error}）。", new Win32Exception(error));
            }
            offset += chunk;
            checkProgress();
        }
        GC.KeepAlive(sourceHandle);
        return length;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct CloneRequest
    {
        public IntPtr Source;
        public long SourceOffset;
        public long TargetOffset;
        public long ByteCount;
    }

    [DllImport("kernel32.dll", EntryPoint = "GetVolumePathNameW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool GetVolumePathName(string file, StringBuilder mount, uint length);

    [DllImport("kernel32.dll", EntryPoint = "GetVolumeInformationW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool GetVolumeInformation(string root, IntPtr label, uint labelLength, out uint serial,
        out uint maxNameLength, out uint flags, StringBuilder format, uint formatLength);

    [DllImport("kernel32.dll", EntryPoint = "GetDiskFreeSpaceW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool GetDiskFreeSpace(string root, out uint sectorsPerCluster, out uint bytesPerSector,
        out uint freeClusters, out uint totalClusters);

    [DllImport("kernel32.dll", EntryPoint = "CreateHardLinkW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateHardLink(string destination, string source, IntPtr securityAttributes);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DeviceIoControl(SafeFileHandle destination, uint command, ref CloneRequest input,
        uint inputSize, IntPtr output, uint outputSize, out uint bytesReturned, IntPtr overlapped);
}
