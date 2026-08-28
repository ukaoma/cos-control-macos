# Bundled animated characters

Each child folder is a processed sprite pack ready for `PetSpriteStore` to copy.
It must include `session-pet-states.json` plus every PNG named by that state map.

Register the folder in `PetSpriteStore.bundledCharacters` with a stable ID and
a resource-relative `folderName`, for example
`BundledCharacters/jedi-example`. The release script copies this root without a
character-specific branch.

Miles remains in `Resources/DefaultPet` for compatibility with existing builds.
