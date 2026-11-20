using System;
using System.IO;
using System.ComponentModel;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

// No recursive deletion by path. Ancestors stay open without delete sharing;
// deletion and object identity are bound to the same Windows handle.
public static class ScienceRootNative {
    [StructLayout(LayoutKind.Sequential)]
    struct FileInfoNative {
        public uint Attr, CreateLow, CreateHigh, AccessLow, AccessHigh, WriteLow, WriteHigh;
        public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct Disposition { public byte Delete; }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security,
        uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInfoNative info);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool SetFileInformationByHandle(SafeFileHandle handle, int cls, ref Disposition info, uint size);
    static SafeFileHandle Open(string path, bool remove, bool exclusive) {
        SafeFileHandle h = CreateFileW(@"\\?\" + path, remove ? 0x10080u : 0x80u, exclusive ? 0u : 3u,
            IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
        if (h.IsInvalid) {
            var error = new Win32Exception(Marshal.GetLastWin32Error());
            h.Dispose();
            throw new IOException(path + ": " + error.Message, error);
        }
        return h;
    }
    static FileInfoNative Read(SafeFileHandle h, string path) {
        FileInfoNative info;
        if (!GetFileInformationByHandle(h, out info)) throw new IOException(path, new Win32Exception());
        if ((info.Attr & 0x400) != 0) throw new IOException("Reparse point: " + path);
        return info;
    }
    static string Signature(FileInfoNative i) {
        return String.Format("{0:x8}:{1:x8}{2:x8}:{3:x8}:{4:x8}{5:x8}:{6:x8}{7:x8}",
            i.Volume, i.IndexHigh, i.IndexLow, i.Attr,
            i.WriteHigh, i.WriteLow, i.SizeHigh, i.SizeLow);
    }
    public static string Inspect(string path, bool testDelete) {
        using (var h=Open(path, testDelete, testDelete)) {
            var i=Read(h,path);
            if (testDelete && (i.Attr & 0x11)==1)
                throw new IOException("Read-only file; attributes will not be changed because the file may have hard links: " + path);
            return Signature(i);
        }
    }
    public sealed class Anchor : IDisposable {
        readonly List<SafeFileHandle> handles=new List<SafeFileHandle>();
        public Anchor(string path, IDictionary<string,string> snapshot) {
            var parents = new Stack<string>();
            for (var d=new DirectoryInfo(Path.GetDirectoryName(path)); d!=null; d=d.Parent) parents.Push(d.FullName);
            try {
                while (parents.Count!=0) {
                    string parent=parents.Pop();
                    var h=Open(parent,false,false); handles.Add(h);
                    var i=Read(h,parent);
                    if ((i.Attr & 0x10)==0) throw new IOException("Parent is not a directory: " + parent);
                    string expected;
                    if (snapshot.TryGetValue(parent,out expected) && !IdentityMatches(Signature(i),expected))
                        throw new IOException("Parent identity changed: " + parent);
                }
            } catch { Dispose(); throw; }
        }
        public void Dispose() { for (int i=handles.Count-1;i>=0;i--) handles[i].Dispose(); }
    }
    static bool IdentityMatches(string actual,string expected) {
        // Deleting children legitimately changes parent timestamps.
        return actual.Substring(0,34).Equals(expected.Substring(0,34),StringComparison.Ordinal);
    }
    public static void Remove(string path, string expected, IDictionary<string,string> snapshot) {
        using (var anchor=new Anchor(path,snapshot))
        using (var h=Open(path,true,true)) {
            var i=Read(h,path); bool dir=(i.Attr & 0x10)!=0;
            if (dir ? !IdentityMatches(Signature(i),expected) : Signature(i)!=expected)
                throw new IOException("Path identity changed: " + path);
            var delete=new Disposition { Delete=1 };
            if (!SetFileInformationByHandle(h,4,ref delete,1)) {
                var error = new Win32Exception(Marshal.GetLastWin32Error());
                throw new IOException("Windows refused to delete " + path + ": " + error.Message, error);
            }
        }
    }
}
