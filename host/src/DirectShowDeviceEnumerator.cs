// Purpose: enumerate the DirectShow video-input category in its native order
// and expose each moniker's identity. OpenCV CAP_DSHOW integer indexes use this
// same category ordering, so capture can bind to Hagibis without guessing.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

namespace CameraRgb565Hdmi.Host
{
    public sealed class DirectShowDevice
    {
        public int Index { get; set; }
        public string FriendlyName { get; set; }
        public string DevicePath { get; set; }
        public string MonikerDisplayName { get; set; }
        // Windows PowerShell 5.1 uses the older C# compiler: initialize here
        // instead of C# 6 auto-property initializers. Empty values fail closed.
        public DirectShowDevice()
        {
            FriendlyName = DevicePath = MonikerDisplayName = "";
        }
    }

    public static class DirectShowDeviceEnumerator
    {
        private static readonly Guid VideoInputDeviceCategory =
            new Guid("860BB310-5D01-11D0-BD3B-00A0C911CE86");

        // Purpose: keep enumeration and COM release inside one bounded method;
        // property failures are represented as empty strings, never as matches.
        public static DirectShowDevice[] Enumerate()
        {
            var devices = new List<DirectShowDevice>();
            var systemEnumeratorType = Type.GetTypeFromCLSID(
                new Guid("62BE5D10-60EB-11D0-BD3B-00A0C911CE86"), true);
            object systemEnumeratorObject = Activator.CreateInstance(systemEnumeratorType);
            ICreateDevEnum systemEnumerator = (ICreateDevEnum)systemEnumeratorObject;
            IEnumMoniker monikerEnumerator = null;
            try
            {
                Guid category = VideoInputDeviceCategory;
                int result = systemEnumerator.CreateClassEnumerator(
                    ref category, out monikerEnumerator, 0);
                if (result != 0 || monikerEnumerator == null)
                    return devices.ToArray();

                var monikers = new IMoniker[1];
                int index = 0;
                while (monikerEnumerator.Next(1, monikers, IntPtr.Zero) == 0)
                {
                    IMoniker moniker = monikers[0];
                    object bagObject = null;
                    try
                    {
                        Guid bagId = typeof(IPropertyBag).GUID;
                        moniker.BindToStorage(null, null, ref bagId, out bagObject);
                        IPropertyBag bag = (IPropertyBag)bagObject;
                        string displayName = "";
                        moniker.GetDisplayName(null, null, out displayName);
                        devices.Add(new DirectShowDevice
                        {
                            Index = index,
                            FriendlyName = ReadString(bag, "FriendlyName"),
                            DevicePath = ReadString(bag, "DevicePath"),
                            MonikerDisplayName = displayName ?? ""
                        });
                    }
                    finally
                    {
                        if (bagObject != null && Marshal.IsComObject(bagObject))
                            Marshal.ReleaseComObject(bagObject);
                        Marshal.ReleaseComObject(moniker);
                    }
                    index++;
                }
            }
            finally
            {
                if (monikerEnumerator != null)
                    Marshal.ReleaseComObject(monikerEnumerator);
                Marshal.ReleaseComObject(systemEnumeratorObject);
            }
            return devices.ToArray();
        }

        private static string ReadString(IPropertyBag bag, string name)
        {
            object value = null;
            try
            {
                return bag.Read(name, ref value, IntPtr.Zero) == 0
                    ? Convert.ToString(value) ?? ""
                    : "";
            }
            catch
            {
                return "";
            }
        }
    }

    [ComImport]
    [Guid("29840822-5B84-11D0-BD3B-00A0C911CE86")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface ICreateDevEnum
    {
        [PreserveSig]
        int CreateClassEnumerator(
            [In] ref Guid category,
            out IEnumMoniker enumMoniker,
            int flags);
    }

    [ComImport]
    [Guid("55272A00-42CB-11CE-8135-00AA004BB851")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IPropertyBag
    {
        [PreserveSig]
        int Read(
            [MarshalAs(UnmanagedType.LPWStr)] string propertyName,
            [In, Out, MarshalAs(UnmanagedType.Struct)] ref object value,
            IntPtr errorLog);

        [PreserveSig]
        int Write(
            [MarshalAs(UnmanagedType.LPWStr)] string propertyName,
            [In, MarshalAs(UnmanagedType.Struct)] ref object value);
    }
}
