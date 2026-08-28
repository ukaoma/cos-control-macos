#!/usr/bin/env python3
"""Static and mutation-tested contract for the compact Session pet settings."""

from __future__ import annotations

import pathlib
import sys


class ContractFailure(AssertionError):
    pass


def need(condition: bool, message: str) -> None:
    if not condition:
        raise ContractFailure(message)


def validate(views: str, models: str) -> None:
    need(
        "@State private var petSettingsExpanded = false" in views
        and "DisclosureGroup(isExpanded: $petSettingsExpanded)" in views,
        "Session pet must default to a collapsed top-level disclosure",
    )
    need(
        "@State private var petStateSpritesExpanded = false" in views
        and "DisclosureGroup(isExpanded: $petStateSpritesExpanded)" in views,
        "state-sprite controls must default to a nested disclosure",
    )
    need(
        "@State private var petCharactersExpanded = false" in views
        and "DisclosureGroup(isExpanded: $petCharactersExpanded)" in views,
        "the character catalog must default to a nested disclosure",
    )

    gallery = views.split("private var petGalleryCard", 1)[1].split(
        "private var sessionPetSettings", 1
    )[0]
    grid = gallery.split("LazyVGrid(", 1)[1]
    need(
        "ForEach(visibleBundledCharacters)" in grid
        and "ForEach(visibleOpenPetsRows)" in grid,
        "bundled and community characters must share one grid",
    )
    need(
        "Ships with COS Control" not in gallery,
        "bundled characters still have a separate catalog heading",
    )
    need(
        'Text("ADVANCED")' in views
        and "character.isAdvanced" in views
        and "let isAdvanced: Bool" in models,
        "the Advanced capability badge is not data-backed and mounted",
    )
    need(
        models.count("isAdvanced: true") == 4,
        "all four shipped Jedi must be registered as Advanced",
    )
    need(
        'TextField("Search characters"' in gallery
        and "visibleBundledCharacters" in gallery
        and "visibleOpenPetsRows" in gallery,
        "one search field must cover the complete combined catalog",
    )


def expect_mutation_failure(name: str, views: str, models: str) -> None:
    try:
        validate(views, models)
    except ContractFailure:
        return
    raise AssertionError(f"mutation canary stayed green: {name}")


def main() -> None:
    root = pathlib.Path(sys.argv[1])
    views = (root / "Sources/Views.swift").read_text()
    models = (root / "Sources/Models.swift").read_text()
    validate(views, models)

    expect_mutation_failure(
        "top-level disclosure defaults open",
        views.replace(
            "@State private var petSettingsExpanded = false",
            "@State private var petSettingsExpanded = true",
            1,
        ),
        models,
    )
    expect_mutation_failure(
        "Advanced badge removed",
        views.replace('Text("ADVANCED")', 'Text("CHARACTER")', 1),
        models,
    )
    expect_mutation_failure(
        "Jedi loses Advanced capability",
        views,
        models.replace("isAdvanced: true", "isAdvanced: false", 1),
    )
    print("COS Control: nested pet settings and unified character gallery passed")


if __name__ == "__main__":
    main()
