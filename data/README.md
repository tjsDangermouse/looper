OSM extracts land here. They are git-ignored: the import script downloads
them, and 'docker compose run --rm graphhopper import <path|url>' rebuilds
the graph from whichever one you point it at.
