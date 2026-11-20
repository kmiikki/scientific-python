using System;
using System.Diagnostics;
using System.IO;
using System.Threading;

// Console output from the timer stays independent of the PowerShell pipeline.
public sealed class SciencePackageProgress : IDisposable
{
    private readonly object gate = new object();
    private readonly Stopwatch clock = Stopwatch.StartNew();
    private readonly TextWriter output = Console.Out;
    private readonly Timer timer;
    private long lastSecond = -1;
    private string activity;
    private Process process;
    private bool stopped;

    public SciencePackageProgress(string initialActivity, int intervalMilliseconds)
    {
        activity = initialActivity;
        Report(null);
        timer = new Timer(Report, null, intervalMilliseconds, intervalMilliseconds);
    }

    public void SetActivity(string description)
    {
        SetActivity(description, null);
    }

    public void SetActivity(string description, Process nativeProcess)
    {
        lock (gate)
        {
            activity = description;
            process = nativeProcess;
        }
    }

    private void Report(object unused)
    {
        lock (gate)
        {
            long seconds = clock.ElapsedMilliseconds / 1000;
            if (stopped || seconds <= lastSecond)
                return;

            string current = activity;
            if (process != null)
            {
                try
                {
                    if (process.HasExited)
                        current = "PowerShell: collecting Micromamba output";
                }
                catch (InvalidOperationException)
                {
                    current = "PowerShell: reading Micromamba output";
                }
                catch (System.ComponentModel.Win32Exception)
                {
                    current = "PowerShell: reading Micromamba output";
                }
            }
            lastSecond = seconds;
            try
            {
                output.WriteLine(
                    "[6/9] Installing packages  RUNNING  Elapsed: {0:00}:{1:00}  {2}",
                    seconds / 60, seconds % 60, current);
                output.Flush();
            }
            catch (IOException)
            {
                // A closed output stream must not interrupt a package commit.
                stopped = true;
            }
            catch (ObjectDisposedException)
            {
                stopped = true;
            }
        }
    }

    public void Dispose()
    {
        lock (gate)
        {
            stopped = true;
            process = null;
            timer.Dispose();
        }
    }
}
