> [!IMPORTANT]
> A bug was found where pages were loaded in the wrong order.
> The best approach would be to look for a ComicInfo.xml and use it, in case it wasn't found fallback to sorting pages lexicographically
> Right now as a fast fix I chose to always sort it lexicographically, but it is a priority to impl a ComicInfo interpreter

# Next

1. src\Comic.zig         |85 col 116|
2. src\window.zig        |213 col 15|
3. src\MemZipIterator.zig|139 col 8 |
