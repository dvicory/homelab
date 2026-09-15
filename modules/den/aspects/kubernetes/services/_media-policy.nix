{
  images = {
    configarr = {
      repository = "docker.io/configarr/configarr";
      tag = "1.30.2";
      digest = "sha256:ec585b6d2530f6090ee26fdcc9701f279666c24dc96c9087208e88ec867c2416";
    };
  };

  # Configarr v1.30.2 consumes these files from the pinned TRaSH-Guides
  # revision. They are copied into a detached local repository before each
  # run, so policy reconstruction never needs the network or a moving branch.
  trashRevision = "04e692c8926f6b9736943afcd9b505bad29f5e54";
  trashRepository = "https://github.com/TRaSH-Guides/Guides";
  trashFiles = {
    radarrMovie = ''
      {
        "trash_id": "aed34b9f60ee115dfa7918b742336277",
        "type": "movie",
        "qualities": [
          { "quality": "HDTV-720p", "min": 17.1, "preferred": 1999, "max": 2000 },
          { "quality": "WEBDL-720p", "min": 12.5, "preferred": 1999, "max": 2000 },
          { "quality": "WEBRip-720p", "min": 12.5, "preferred": 1999, "max": 2000 },
          { "quality": "Bluray-720p", "min": 25.7, "preferred": 1999, "max": 2000 },
          { "quality": "HDTV-1080p", "min": 33.8, "preferred": 1999, "max": 2000 },
          { "quality": "WEBDL-1080p", "min": 12.5, "preferred": 1999, "max": 2000 },
          { "quality": "WEBRip-1080p", "min": 12.5, "preferred": 1999, "max": 2000 },
          { "quality": "Bluray-1080p", "min": 50.8, "preferred": 1999, "max": 2000 },
          { "quality": "Remux-1080p", "min": 102, "preferred": 1999, "max": 2000 },
          { "quality": "HDTV-2160p", "min": 85, "preferred": 1999, "max": 2000 },
          { "quality": "WEBDL-2160p", "min": 34.5, "preferred": 1999, "max": 2000 },
          { "quality": "WEBRip-2160p", "min": 34.5, "preferred": 1999, "max": 2000 },
          { "quality": "Bluray-2160p", "min": 102, "preferred": 1999, "max": 2000 },
          { "quality": "Remux-2160p", "min": 187.4, "preferred": 1999, "max": 2000 }
        ]
      }
    '';
    sonarrSeries = ''
      {
        "trash_id": "bef99584217af744e404ed44a33af589",
        "type": "series",
        "qualities": [
          { "quality": "HDTV-720p", "min": 10, "preferred": 995, "max": 1000 },
          { "quality": "HDTV-1080p", "min": 15, "preferred": 995, "max": 1000 },
          { "quality": "WEBRip-720p", "min": 10, "preferred": 995, "max": 1000 },
          { "quality": "WEBDL-720p", "min": 10, "preferred": 995, "max": 1000 },
          { "quality": "Bluray-720p", "min": 17.1, "preferred": 995, "max": 1000 },
          { "quality": "WEBRip-1080p", "min": 15, "preferred": 995, "max": 1000 },
          { "quality": "WEBDL-1080p", "min": 15, "preferred": 995, "max": 1000 },
          { "quality": "Bluray-1080p", "min": 50.4, "preferred": 995, "max": 1000 },
          { "quality": "Bluray-1080p Remux", "min": 69.1, "preferred": 995, "max": 1000 },
          { "quality": "HDTV-2160p", "min": 25, "preferred": 995, "max": 1000 },
          { "quality": "WEBRip-2160p", "min": 25, "preferred": 995, "max": 1000 },
          { "quality": "WEBDL-2160p", "min": 25, "preferred": 995, "max": 1000 },
          { "quality": "Bluray-2160p", "min": 94.6, "preferred": 995, "max": 1000 },
          { "quality": "Bluray-2160p Remux", "min": 187.4, "preferred": 995, "max": 1000 }
        ]
      }
    '';
    sonarrAnime = ''
      {
        "trash_id": "387e6278d8e06083d813358762e0ac63",
        "type": "anime",
        "qualities": [
          { "quality": "SDTV", "min": 5, "preferred": 995, "max": 1000 },
          { "quality": "WEBRip-480p", "min": 5, "preferred": 995, "max": 1000 },
          { "quality": "WEBDL-480p", "min": 5, "preferred": 995, "max": 1000 },
          { "quality": "DVD", "min": 5, "preferred": 995, "max": 1000 },
          { "quality": "Bluray-480p", "min": 5, "preferred": 995, "max": 1000 },
          { "quality": "Bluray-576p", "min": 5, "preferred": 995, "max": 1000 },
          { "quality": "HDTV-720p", "min": 5, "preferred": 995, "max": 1000 },
          { "quality": "HDTV-1080p", "min": 5, "preferred": 995, "max": 1000 },
          { "quality": "WEBRip-720p", "min": 5, "preferred": 995, "max": 1000 },
          { "quality": "WEBDL-720p", "min": 5, "preferred": 995, "max": 1000 },
          { "quality": "Bluray-720p", "min": 5, "preferred": 995, "max": 1000 },
          { "quality": "WEBRip-1080p", "min": 5, "preferred": 995, "max": 1000 },
          { "quality": "WEBDL-1080p", "min": 5, "preferred": 995, "max": 1000 },
          { "quality": "Bluray-1080p", "min": 5, "preferred": 995, "max": 1000 },
          { "quality": "Bluray-1080p Remux", "min": 5, "preferred": 995, "max": 1000 },
          { "quality": "HDTV-2160p", "min": 5, "preferred": 995, "max": 1000 },
          { "quality": "WEBRip-2160p", "min": 5, "preferred": 995, "max": 1000 },
          { "quality": "WEBDL-2160p", "min": 5, "preferred": 995, "max": 1000 },
          { "quality": "Bluray-2160p", "min": 5, "preferred": 995, "max": 1000 },
          { "quality": "Bluray-2160p Remux", "min": 5, "preferred": 995, "max": 1000 }
        ]
      }
    '';
  };
}
