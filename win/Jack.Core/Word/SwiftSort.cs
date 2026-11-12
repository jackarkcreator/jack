// Swift's standard-library sort, step for step, so the port orders items exactly as the Mac does.
//
// Why not LINQ OrderBy: every comparator in the engine but one is a plain key comparison, where
// any stable sort gives the same answer (Swift's sort is stable). The exception is the reading
// order of OCR lines ("same band → left to right, else top to bottom"), which is not transitive:
// there the result depends on the algorithm itself. So the engine uses this port everywhere.
//
// Source: Swift 5 stdlib (Sort.swift), read from the macOS SDK's Swift.swiftinterface:
// insertion sort when count < 64, otherwise run detection + insertion-sort extension to the
// minimum run length + merges keeping the run-length invariants, then a final merge.
namespace Jack.Core.Word;

public static class SwiftSort
{
    /// `list.sort(by:)`
    public static void Sort<T>(List<T> list, Func<T, T, bool> areInIncreasingOrder)
    {
        var a = list.ToArray();
        SortArray(a, areInIncreasingOrder);
        for (int i = 0; i < a.Length; i++) list[i] = a[i];
    }

    /// `sequence.sorted(by:)`
    public static List<T> Sorted<T>(IEnumerable<T> source, Func<T, T, bool> areInIncreasingOrder)
    {
        var a = source.ToArray();
        SortArray(a, areInIncreasingOrder);
        return new List<T>(a);
    }

    /// `[CGFloat].sorted()`
    public static List<double> Sorted(IEnumerable<double> source) => Sorted(source, (x, y) => x < y);

    static void SortArray<T>(T[] e, Func<T, T, bool> less)
    {
        int count = e.Length;
        int minimumRunLength = MinimumMergeRunLength(count);
        if (count <= minimumRunLength)
        {
            InsertionSort(e, 0, count, less);
            return;
        }
        var buffer = new T[count / 2];
        var runs = new List<(int Lo, int Hi)>();
        int start = 0;
        while (start < count)
        {
            var (end, descending) = FindNextRun(e, start, less);
            if (descending) Reverse(e, start, end);
            // If the current run is shorter than the minimum length, use the insertion sort to extend it.
            if (end < count && end - start < minimumRunLength)
            {
                int newEnd = Math.Min(count, start + minimumRunLength);
                InsertionSort(e, start, newEnd, end, less);
                end = newEnd;
            }
            runs.Add((start, end));
            MergeTopRuns(e, runs, buffer, less);
            start = end;
        }
        while (runs.Count > 1) MergeRuns(e, runs, runs.Count - 1, buffer, less);
    }

    static int MinimumMergeRunLength(int c)
    {
        const int bitsToUse = 6;
        if (c < 1 << bitsToUse) return c;
        long cl = c;
        int offset = (64 - bitsToUse) - System.Numerics.BitOperations.LeadingZeroCount((ulong)cl);
        long mask = (1L << offset) - 1;
        return (int)((cl >> offset) + ((cl & mask) == 0 ? 0 : 1));
    }

    static void InsertionSort<T>(T[] e, int lo, int hi, Func<T, T, bool> less)
    {
        if (lo == hi) return;
        InsertionSort(e, lo, hi, lo + 1, less);
    }

    static void InsertionSort<T>(T[] e, int lo, int hi, int sortedEnd, Func<T, T, bool> less)
    {
        while (sortedEnd != hi)
        {
            int i = sortedEnd;
            do
            {
                int j = i - 1;
                if (!less(e[i], e[j])) break;
                (e[i], e[j]) = (e[j], e[i]);
                i = j;
            } while (i != lo);
            sortedEnd++;
        }
    }

    static void Reverse<T>(T[] e, int lo, int hi)
    {
        int f = lo, l = hi;
        while (f < l)
        {
            l--;
            (e[f], e[l]) = (e[l], e[f]);
            f++;
        }
    }

    static (int End, bool Descending) FindNextRun<T>(T[] e, int start, Func<T, T, bool> less)
    {
        int previous = start;
        int current = start + 1;
        if (current >= e.Length) return (current, false);
        // An ascending run can include consecutive equal elements, but because a descending run
        // will be reversed, it must be strictly descending.
        bool isDescending = less(e[current], e[previous]);
        do
        {
            previous = current;
            current++;
        } while (current < e.Length && isDescending == less(e[current], e[previous]));
        return (current, isDescending);
    }

    static void Merge<T>(T[] e, int low, int mid, int high, T[] buffer, Func<T, T, bool> less)
    {
        int lowCount = mid - low, highCount = high - mid;
        int destLow = low, bufferLow = 0, bufferHigh = 0;
        if (lowCount < highCount)
        {
            Array.Copy(e, low, buffer, 0, lowCount);
            bufferHigh = lowCount;
            int srcLow = mid;
            // Each iteration moves the element that compares lower into destLow, preferring the
            // buffer when equal to maintain stability.
            while (bufferLow < bufferHigh && srcLow < high)
            {
                if (less(e[srcLow], buffer[bufferLow])) { e[destLow] = e[srcLow]; srcLow++; }
                else { e[destLow] = buffer[bufferLow]; bufferLow++; }
                destLow++;
            }
        }
        else
        {
            Array.Copy(e, mid, buffer, 0, highCount);
            bufferHigh = highCount;
            int destHigh = high, srcHigh = mid;
            destLow = mid;
            // Each iteration moves the element that compares higher into destHigh, preferring the
            // buffer when equal to maintain stability.
            while (bufferHigh > bufferLow && srcHigh > low)
            {
                destHigh--;
                if (less(buffer[bufferHigh - 1], e[srcHigh - 1]))
                {
                    srcHigh--;
                    e[destHigh] = e[srcHigh];
                    destLow--;
                }
                else
                {
                    bufferHigh--;
                    e[destHigh] = buffer[bufferHigh];
                }
            }
        }
        // (Swift's `defer`) whatever is left in the buffer goes to destLow.
        Array.Copy(buffer, bufferLow, e, destLow, bufferHigh - bufferLow);
    }

    static void MergeRuns<T>(T[] e, List<(int Lo, int Hi)> runs, int i, T[] buffer, Func<T, T, bool> less)
    {
        int low = runs[i - 1].Lo, middle = runs[i].Lo, high = runs[i].Hi;
        Merge(e, low, middle, high, buffer, less);
        runs[i - 1] = (low, high);
        runs.RemoveAt(i);
    }

    static void MergeTopRuns<T>(T[] e, List<(int Lo, int Hi)> runs, T[] buffer, Func<T, T, bool> less)
    {
        static int N((int Lo, int Hi) r) => r.Hi - r.Lo;
        while (runs.Count > 1)
        {
            int lastIndex = runs.Count - 1;
            if (lastIndex >= 3 && N(runs[lastIndex - 3]) <= N(runs[lastIndex - 2]) + N(runs[lastIndex - 1]))
            {
                if (N(runs[lastIndex - 2]) < N(runs[lastIndex])) lastIndex -= 1;
            }
            else if (lastIndex >= 2 && N(runs[lastIndex - 2]) <= N(runs[lastIndex - 1]) + N(runs[lastIndex]))
            {
                if (N(runs[lastIndex - 2]) < N(runs[lastIndex])) lastIndex -= 1;
            }
            else if (N(runs[lastIndex - 1]) <= N(runs[lastIndex]))
            {
                // Y <= Z, so merge Y and Z
            }
            else
            {
                break;
            }
            MergeRuns(e, runs, lastIndex, buffer, less);
        }
    }
}
