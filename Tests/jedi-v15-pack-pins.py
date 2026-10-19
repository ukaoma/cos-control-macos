#!/usr/bin/env python3
"""0.5.328: the bundled Jedi Miles Windu pack is Version 15 (V15), "V14 to V15: 2x retina pack" (Miles 2026-10-19:
"deploy these updated sprites for our jedi. Needs to be the default for our future releases as well"; 13:59: deploy
at 2x retina once regressions are cleared). Baked by installation-v1-5/bake_v15.py in the COS repo
(render-receipt-v15.json, map sha256 af4fc61d..., pack sha256 07ee41d2...). V14 timing-v2 is the rollback.

Pins, each checked once on the real tree and then required to FAIL on in-memory mutations that provably land:
  - every file the shipped map names (1x and retina), by sha256, PNG size, colour type and byte count, and the map;
  - the casts: four on Session 1 (working), three on duel, trio and swarm, their handoffs and flat names;
  - the retina blocks: scale 2, the same cast ids in order, each strip's ordered segments tiling the 1x strip's frames
    at twice its cell (so the figure is the same size on screen), every segment under the native caps;
  - names: every new file carries the windu-pack15- prefix, none ends in -v15.png (older strips use that suffix for an
    unrelated numbering) and none collides with another DefaultPet file, case-insensitively;
  - the retained V14 strips the upgrade compares installed bytes against, and the source wiring: V14 strips recognized
    as stock, Session 1 casts loaded, retina strips chosen by the pet window's backing scale, art generation 23, no
    file removal in the upgrade;
  - no stale V14 cast layer and no orphan pack file ships, and scripts/build-release.sh copies the flat files.

    python3 Tests/jedi-v15-pack-pins.py <root> [-v]   (-v names the check that caught each mutant)
"""
from __future__ import annotations

import hashlib
import json
import pathlib
import re
import struct
import sys
from typing import Callable

P = "windu-pack15-"
MANIFEST_SHA = "af4fc61df77344d955633563cef7b0c55fd7dc39a02753c443d26d9f16f4d134"
# name: (sha256, width, height, bytes). The V15 1x and retina strips, then the three V14 ambient strips V15 keeps.
PINNED = {
    P + "attention-1x.png": ("297ac39bb832362664a16655f36a7ad2a6775791921304d18bc5b2061810ac3c", 2178, 256, 184160),
    P + "attention-2x.png": ("6dcbc512187f46ffa395c142a126f43fa080b7346ba6081f9c657c1d09c10767", 4356, 512, 577716),
    P + "done-1x.png": ("ec06c8b60180e8626de9350e97998859d18e886f6816e6670f54998aab95959d", 2394, 256, 188128),
    P + "done-2x.png": ("be468e15771de61293e9fdc32a779ad25deaa06499cf0de3785e156e70f44141", 4788, 512, 585258),
    P + "duel-a-body-1x.png": ("955959a46291ef1c6aa38994cca7f00005465de7056795c2ce0c48573f86bad9", 11248, 256, 1136636),
    P + "duel-a-body-2x.png": ("48d7cea2f2fd8ac132c7312d25816f868b6c1ef27544ccdbb540aa33919d5dbb", 22496, 512, 3414769),
    P + "duel-a-entry-1x.png": ("9080517f22cc5f5a60b9ab55e09f012a74ac25d13043a3a5f72dd7e2efdbf767", 11248, 256, 99728),
    P + "duel-a-entry-2x.png": ("77ed6305853e081d0298651acfdaa5cf03c1b19c8497b57f31b14b5a4c158202", 22496, 512, 299647),
    P + "duel-a-full-1x.png": ("b0b90ecb9ed75125f7d463b6c602e525058f77af5cf3140cde20142a94c450f7", 11248, 256, 1217093),
    P + "duel-a-full-2x.png": ("0c4a07817333e4a1331cd32d30177be2814b3af2c39bb9d42c3c654ed13078b8", 22496, 512, 3640434),
    P + "duel-b-body-1x.png": ("eb0998c86c87d5f2972c27b6283d6c79e35d4fdd1d1ecca1a1e08fc86364df6e", 11248, 256, 1107197),
    P + "duel-b-body-2x.png": ("4432b434c606a9195c97984bfef0f1dc90544e919a33382f9871af1e26591bd6", 22496, 512, 3311950),
    P + "duel-b-entry-1x.png": ("3022b5ad974fae8f542adfece2eb12b5d5ec06918df01f43fe2ef8c730129090", 11248, 256, 118167),
    P + "duel-b-entry-2x.png": ("09d3fa23b873a53fe944a8a1cca79193a1ad5493def8c5a2715b4223297cda42", 22496, 512, 356195),
    P + "duel-b-full-1x.png": ("170a9ee195dd20ece6cba048c77376fe19a83bb0be394645ba52071b361a194a", 11248, 256, 1203798),
    P + "duel-b-full-2x.png": ("20e1414aa592169e648ff50db93051acfb4b50c64b303e6ec053e4a1fe4e6645", 22496, 512, 3587219),
    P + "duel-c-body-1x.png": ("5f0a6cb907ae8e715ad74b2d46a07206ec9a3ff9a1bcceaf1e4446d6fbb31a4f", 11248, 256, 1137071),
    P + "duel-c-body-2x.png": ("2d5b4e8a20d34b63fbc2ce5153448e95e570d0223581f068c575ec2b32e2ee3e", 22496, 512, 3415900),
    P + "duel-c-entry-1x.png": ("39fe372346093a5d224a2ffb8bdfce69322fb55395fb49fa3ab15d64a32ee710", 11248, 256, 110830),
    P + "duel-c-entry-2x.png": ("61b2ba96085a4a0dd15124a92b850754315acb78869240b10725679348fa59e2", 22496, 512, 327583),
    P + "duel-c-full-1x.png": ("c52a695795aa18cfe2b70bac4e6bbcef5fb5b5b42f2575d41ea9154ab00b8703", 11248, 256, 1226428),
    P + "duel-c-full-2x.png": ("74936f3f662eea54a3d299f81c5f7d1ef6beb0549ca6644e21ba555743d69fc0", 22496, 512, 3665269),
    P + "error-1x.png": ("817e9c1ee474d4ae94a50c13fa3caa802b2e9647a1ade411221f6375ac050d66", 1792, 256, 145573),
    P + "error-2x.png": ("d5e035293cb686f3da835e0f0918d5e4f9b0c23a9426bcbd54349175b23beb93", 3584, 512, 441351),
    P + "swarm-a-body-1x.png": ("86ab7bfbc98494fbbe89cb22c31c092ad8fdec8e9621ca1c9d08584a3652c35d", 19904, 256, 2119881),
    P + "swarm-a-body-2x-s1.png": ("d2a6678efbe06fa181ce0af9ad5003d1e432570d9d11dd124ff310bab40dc9bd", 19904, 512, 3599626),
    P + "swarm-a-body-2x-s2.png": ("c58cd0eea8b5d3d7a840a70be8062133ee14509d57c18db92204e5bd8acfc376", 19904, 512, 2940873),
    P + "swarm-a-entry-1x.png": ("eaa365f32cf9d3ab53ba7cbaedad6458e257443e00d4163199ab21adc9634598", 19904, 256, 188337),
    P + "swarm-a-entry-2x-s1.png": ("38297cc524ce5061307ab5d13f0c3644db488b16183f7c29c4434876573954cf", 19904, 512, 39630),
    P + "swarm-a-entry-2x-s2.png": ("8ad86dcd1e1c12762cb40301ed0817c6d8bc063c289413cc8619b6ae5c17108f", 19904, 512, 539671),
    P + "swarm-a-full-1x.png": ("30d20ce1f45dc76352be84150b773c9c4cbba09adeaf2bdf6e3507f2909f3d78", 19904, 256, 2267671),
    P + "swarm-a-full-2x-s1.png": ("d2a6678efbe06fa181ce0af9ad5003d1e432570d9d11dd124ff310bab40dc9bd", 19904, 512, 3599626),
    P + "swarm-a-full-2x-s2.png": ("de309d148e72801ae9017539ccdf244ba098bc285ccbec59cbdc561dccfb7dee", 19904, 512, 3396081),
    P + "swarm-b-body-1x.png": ("2fb54010c5d820de0813b53e7704dcd6904d7488d9251fce8bbf46a337e9d3d3", 19904, 256, 2058749),
    P + "swarm-b-body-2x-s1.png": ("4a79acae8c0ce8a8fa6274377b286fad92ec9048c84c806813e2454ea91a827c", 19904, 512, 3487413),
    P + "swarm-b-body-2x-s2.png": ("ced3e2f38979a3662ec794c18a71c56041434b159deab8b49d3a5d36422b9c8b", 19904, 512, 2842945),
    P + "swarm-b-entry-1x.png": ("e13cdbbd68120bae4fe0ba61e1973c5867a44875a17ddf45ecc941b9f5ecc1ee", 19904, 256, 186445),
    P + "swarm-b-entry-2x-s1.png": ("38297cc524ce5061307ab5d13f0c3644db488b16183f7c29c4434876573954cf", 19904, 512, 39630),
    P + "swarm-b-entry-2x-s2.png": ("5e20f0ac8bd8b9722272775cd323fa22cf58a5d93cf0f319267bce9395befc78", 19904, 512, 533833),
    P + "swarm-b-full-1x.png": ("8d7e76e06ab7c0e24bc7280b9ca9d2bfe9c4dc8eebbf7638b8c173cdde40b0bc", 19904, 256, 2203822),
    P + "swarm-b-full-2x-s1.png": ("4a79acae8c0ce8a8fa6274377b286fad92ec9048c84c806813e2454ea91a827c", 19904, 512, 3487413),
    P + "swarm-b-full-2x-s2.png": ("86d12e7995b43e85196f383a7c7534dab7cf9789fa0aebe1301bbef735ec745b", 19904, 512, 3290044),
    P + "swarm-c-body-1x.png": ("8301f268aebc9e2588bb4798f2daee114e99f9af8942ae4683f8ed28e1695cac", 19904, 256, 2115810),
    P + "swarm-c-body-2x-s1.png": ("ed5e43197598047c742772d440a353b324caa5de88afc114733e544cad98b6f9", 19904, 512, 3601044),
    P + "swarm-c-body-2x-s2.png": ("2c37809e2302f9f48bdd305b68fdddd94dd5f921f017bb1c302ffd175c467648", 19904, 512, 2914322),
    P + "swarm-c-entry-1x.png": ("3240de6fccd202230802c684796e6fc612d613d126e0db4ae593138748d334ca", 19904, 256, 196337),
    P + "swarm-c-entry-2x-s1.png": ("38297cc524ce5061307ab5d13f0c3644db488b16183f7c29c4434876573954cf", 19904, 512, 39630),
    P + "swarm-c-entry-2x-s2.png": ("f7e1dee6d8ec7fd520d75ce1b56f368a79db0f08041f8be10d79ab7bde9aa82d", 19904, 512, 567287),
    P + "swarm-c-full-1x.png": ("9eb9348dc96a0a23efb9d483f8101017acd67694ee65d00694940694fbb8003c", 19904, 256, 2270867),
    P + "swarm-c-full-2x-s1.png": ("ed5e43197598047c742772d440a353b324caa5de88afc114733e544cad98b6f9", 19904, 512, 3601044),
    P + "swarm-c-full-2x-s2.png": ("d2f7c1b38914b4f2aadf18290a07b768e247de1cdf5271396eb8edb9c699beca", 19904, 512, 3393842),
    P + "trio-a-body-1x.png": ("92992cefca2fd8884389b49cd169ff972689cf7fc632ae53de7caa0ef936e5ae", 12298, 256, 1446689),
    P + "trio-a-body-2x.png": ("faf351b344a528c241e4761d6661638164c0e725a977951ceab25bb342b7bd38", 24596, 512, 4000649),
    P + "trio-a-entry-1x.png": ("3b9b6952bf66660353ec365e74a104a196a35b8dd60767c158037f13c104cd59", 12298, 256, 206259),
    P + "trio-a-entry-2x.png": ("25d7b6f0a0f886bfbd9cb3fdbf5cb4bf29bd73261dd006571eb60b0849603e63", 24596, 512, 539897),
    P + "trio-a-full-1x.png": ("06b1a51da42f567115453baeb1c8e25fc7b1f7816c1628ada6ab61ce6ec571d5", 12298, 256, 1583388),
    P + "trio-a-full-2x.png": ("6c60149a230178d5cd08a0d36814c736d7f111c0e1ef64ae3e24df2eb548747c", 24596, 512, 4392088),
    P + "trio-b-body-1x.png": ("8ed86e9973299f766efaeff662b18134b9ea42774ca828f6d4536d830b974f76", 12298, 256, 1356381),
    P + "trio-b-body-2x.png": ("8e5b48c53509cbd4afb0012d9b88d3f6e60568624801533d12ac63184545914b", 24596, 512, 3783563),
    P + "trio-b-entry-1x.png": ("ab8c272b9c9ee40730a3310c07b2d2b0764c0cdd2e257bcd0bb3815828b7fc2c", 12298, 256, 191378),
    P + "trio-b-entry-2x.png": ("3f707efcd632195e9abd6cddb7ba05350a59d137e3c40be708e6d9c6b146eace", 24596, 512, 501725),
    P + "trio-b-full-1x.png": ("b713a261942dd9038acc794ff3bd56df0dfeea81d968aba12bb5eba0d1f46d91", 12298, 256, 1490528),
    P + "trio-b-full-2x.png": ("1669ab1565d65519400edcde06ef52b4b62cc0512396fd9a1c33dc78a4900efc", 24596, 512, 4170743),
    P + "trio-c-body-1x.png": ("d732898e7f9a8a8a69839ace4dd96c839dd3740409dc7acc65560af4b75329d8", 12298, 256, 1436442),
    P + "trio-c-body-2x.png": ("fe606601294edfb40eee0d7aa748affc806e86a6041a73e791fa11bfc6469be3", 24596, 512, 3951290),
    P + "trio-c-entry-1x.png": ("716ad0988ab38bdcfd4f538d23045bc43548e8a2aa785c7b720454de729346e2", 12298, 256, 216814),
    P + "trio-c-entry-2x.png": ("f239152904dbf3959fda3ff916fa95a316c4e1a148cdc7fc4f2c24b99d87d1f8", 24596, 512, 563694),
    P + "trio-c-full-1x.png": ("50242cf98ac628f98f28cd5b2e1fba2f31f54f7b6f3dd48147947bf905501922", 12298, 256, 1583826),
    P + "trio-c-full-2x.png": ("5fd5e5f9779e8260b0c28df2addbcb2da61ff35f6c13ab65be5dba3efddd0ed1", 24596, 512, 4364736),
    P + "working-a-body-1x.png": ("ea3930aa08c188c5ec691a0f427e314b931722e89766f507eada01769c1e5b19", 13984, 256, 1006902),
    P + "working-a-body-2x.png": ("b2a9db6b91776db2a5c2a5102df6eb802a877f61845346a997f5495d2010e464", 27968, 512, 3335753),
    P + "working-a-entry-1x.png": ("db8e15e81e2502758bb933ed04b9c8a27a2c48e8c4efdb5cd136ff8775359724", 13984, 256, 13968),
    P + "working-a-entry-2x.png": ("1ddc2252b5e51feabfa5e517be2f71719c5619aedcca53e9ec1948d4d30985ff", 27968, 512, 55658),
    P + "working-a-full-1x.png": ("ea3930aa08c188c5ec691a0f427e314b931722e89766f507eada01769c1e5b19", 13984, 256, 1006902),
    P + "working-a-full-2x.png": ("b2a9db6b91776db2a5c2a5102df6eb802a877f61845346a997f5495d2010e464", 27968, 512, 3335753),
    P + "working-b-body-1x.png": ("d279cbf68b15a38695da14926f4c5f8d67a654dfc61335951f15c04f25065304", 13984, 256, 1058975),
    P + "working-b-body-2x.png": ("34b9a3ec81b6195bd151e070cf31cf25778aff4d51beb2ebf5ef276a86043663", 27968, 512, 3494029),
    P + "working-b-entry-1x.png": ("db8e15e81e2502758bb933ed04b9c8a27a2c48e8c4efdb5cd136ff8775359724", 13984, 256, 13968),
    P + "working-b-entry-2x.png": ("1ddc2252b5e51feabfa5e517be2f71719c5619aedcca53e9ec1948d4d30985ff", 27968, 512, 55658),
    P + "working-b-full-1x.png": ("d279cbf68b15a38695da14926f4c5f8d67a654dfc61335951f15c04f25065304", 13984, 256, 1058975),
    P + "working-b-full-2x.png": ("34b9a3ec81b6195bd151e070cf31cf25778aff4d51beb2ebf5ef276a86043663", 27968, 512, 3494029),
    P + "working-c-body-1x.png": ("3679c33b888481d9a588837416f6ad10f5598a82ad1348807a440867890e4f6c", 13984, 256, 1040672),
    P + "working-c-body-2x.png": ("eb3c1575cf5c4b6b582408b8a51342859e7518d6082c6f1ad8b81dbf1f2946b4", 27968, 512, 3437665),
    P + "working-c-entry-1x.png": ("db8e15e81e2502758bb933ed04b9c8a27a2c48e8c4efdb5cd136ff8775359724", 13984, 256, 13968),
    P + "working-c-entry-2x.png": ("1ddc2252b5e51feabfa5e517be2f71719c5619aedcca53e9ec1948d4d30985ff", 27968, 512, 55658),
    P + "working-c-full-1x.png": ("3679c33b888481d9a588837416f6ad10f5598a82ad1348807a440867890e4f6c", 13984, 256, 1040672),
    P + "working-c-full-2x.png": ("eb3c1575cf5c4b6b582408b8a51342859e7518d6082c6f1ad8b81dbf1f2946b4", 27968, 512, 3437665),
    P + "working-d-body-1x.png": ("920af6b9780e09611a9bc3c21878b7f29ca6a53a36f70565a654335c69d2e2b0", 13984, 256, 1024617),
    P + "working-d-body-2x.png": ("6bcd8689f7798abd2c5ebbd4b22de243051a29bc4b9519d0f4060c601ea0f805", 27968, 512, 3394220),
    P + "working-d-entry-1x.png": ("db8e15e81e2502758bb933ed04b9c8a27a2c48e8c4efdb5cd136ff8775359724", 13984, 256, 13968),
    P + "working-d-entry-2x.png": ("1ddc2252b5e51feabfa5e517be2f71719c5619aedcca53e9ec1948d4d30985ff", 27968, 512, 55658),
    P + "working-d-full-1x.png": ("920af6b9780e09611a9bc3c21878b7f29ca6a53a36f70565a654335c69d2e2b0", 13984, 256, 1024617),
    P + "working-d-full-2x.png": ("6bcd8689f7798abd2c5ebbd4b22de243051a29bc4b9519d0f4060c601ea0f805", 27968, 512, 3394220),
    "session-pet-idle-cutouts-v2.png": ("f16814c7139b1d72009c755497f9e97b9100635c86cde123bbc232565ae6e33c", 664, 256, 146417),
    "session-pet-patrol-polish-v3.png": ("c1340d57fd902522cc686664b225358b14a9d3246eada3e98221fbedd9efc4c6", 1024, 256, 146340),
    "session-pet-waiting-release-v1.png": ("e885beb423f2e8febd348d0a8fc566ed2e20da6c1b78bbe33efc3a9aa6b765f3", 1067, 256, 147023),
}
# The V14 timing-v2 Sessions 1 to 4. Not in the map any more; the upgrade compares an installed V14 against these bytes.
RETAINED_V14 = {
    "session-pet-working-v13.png": ("4df56c59db80b8041de5a6f24a56eeadbaa26afca23be4af1c93b702ff5c2c52", 46),
    "session-pet-duel-v13.png": ("e0d1fc28f3eb8c89b74514687272d7290fe0a56577f14ee064f91f35af50b51d", 37),
    "session-pet-trio-v13.png": ("397e277d2c566ae9e8f418ec5af850420aeac1dd95f824beff1b6f330b1b0096", 43),
    "session-pet-swarm-v13.png": ("a9a16a873f6098219b9b5b26f8f9e9deebf4e33cb194e8e83a577ac2417186cd", 64),
}
# pose: (frames, interval, 1x cell width, handoff, casts).
CASTS = {"working": (46, 0.08, 304, 37, "abcd"), "duel": (37, 0.08, 304, 28, "abc"),
         "trio": (43, 0.08, 286, 31, "abc"), "swarm": (64, 0.08, 311, 55, "abc")}
SIGNALS = {"attention": (18, 0.12, 121), "done": (14, 0.14, 171), "error": (8, 0.14, 224)}
KINDS = (("file", "full"), ("bodyFile", "body"), ("entryFile", "entry"))


class Fail(AssertionError):
    pass


def need(ok: bool, why: str) -> None:
    if not ok:
        raise Fail(why)


def png(data: bytes, name: str) -> tuple[int, int, int]:
    need(data[:8] == b"\x89PNG\r\n\x1a\n" and data[12:16] == b"IHDR", f"{name} is not a PNG")
    width, height, _, colour = struct.unpack(">IIBB", data[16:26])
    return width, height, colour


def segments_tile(names: list[str], frames: int, cell: int, stem: str) -> None:
    need(names == [f"{stem}-2x.png"] or names == [f"{stem}-2x-s{i + 1}.png" for i in range(len(names))],
         f"{stem} retina segments are named in order: {names}")
    widths = [PINNED[n][1] for n in names]
    need(all(PINNED[n][2] == 512 and w % (2 * cell) == 0 and w <= 32760 and w * 512 <= 16_777_216 for n, w in zip(names, widths)),
         f"{stem} retina segments are 512 px high, cut at {2 * cell} px cells and under the native caps")
    need(sum(widths) == frames * 2 * cell, f"{stem} retina segments tile {frames} cells of {2 * cell} px")


def validate(map_bytes: bytes, read: Callable[[str], bytes | None], listing: set[str], release: str, models: str,
             controller: str, pet: str, pin_map: bool = True) -> int:
    # Map mutants run with pin_map=False so each structural check below must catch them on its own.
    need(not pin_map or hashlib.sha256(map_bytes).hexdigest() == MANIFEST_SHA, "the shipped map drifted from the approved V15 map")
    poses = json.loads(map_bytes)["poses"]
    need(sorted(p for p, row in poses.items() if "rotation" in row) == sorted(CASTS),
         "casts rotate on working, duel, trio and swarm, and on no other pose")
    need(sorted(p for p, row in poses.items() if "retina" in row) == sorted([*CASTS, *SIGNALS]),
         "retina strips on the seven V15 poses only (idle, patrol and waiting are V14's 1x art)")
    referenced: list[str] = []
    for row in poses.values():
        referenced.append(row["file"])
        for variant in row.get("rotation", {}).get("variants", []):
            referenced += [variant[k] for k, _ in KINDS]
        retina = row.get("retina", {})
        referenced += retina.get("file", []) + [n for v in retina.get("variants", []) for k, _ in KINDS for n in v[k]]
    for name in referenced:
        need("/" not in name and name.endswith(".png"), f"{name} must be a flat .png (the release copies DefaultPet/*.png only)")
        need(name in listing, f"the map names {name}, which is not in Resources/DefaultPet")
    need('cp "$ROOT/Resources/DefaultPet/"*.png "$ROOT/Resources/DefaultPet/"*.json' in release,
         "scripts/build-release.sh ships DefaultPet's flat .png and .json files")
    for pose, (frames, interval, cell, handoff, casts) in CASTS.items():
        row = poses[pose]
        need(row["frames"] == frames and row["interval"] == interval, f"{pose} plays {frames} frames at {interval}s")
        rotation = row["rotation"]
        need(rotation.get("version") == 1 and rotation.get("handoffFrame") == handoff and "seed" not in rotation,
             f"{pose} hands off at frame {handoff}, unseeded")
        variants = rotation.get("variants", [])
        need([v["id"] for v in variants] == [f"{pose}-{c}" for c in casts], f"{pose} casts are {pose}-{', -'.join(casts)} in order")
        for v in variants:
            for key, kind in KINDS:
                need(v[key] == f"{P}{v['id']}-{kind}-1x.png", f"{pose} {v['id']} {key} is {v[key]}")
        need(row["file"] == variants[0]["file"], f"{pose} falls back to its first cast's full strip")
        need(PINNED[row["file"]][1:3] == (frames * cell, 256), f"{pose} is {frames} cells of {cell}x256 px at 1x")
        retina = row["retina"]
        need(retina.get("scale") == 2 and [v["id"] for v in retina.get("variants", [])] == [v["id"] for v in variants],
             f"{pose} retina is scale 2 with the same casts in the same order")
        need(retina["file"] == retina["variants"][0]["file"], f"{pose} retina falls back to its first cast")
        for v in retina["variants"]:
            for key, kind in KINDS:
                segments_tile(v[key], frames, cell, f"{P}{v['id']}-{kind}")
    for pose, (frames, interval, cell) in SIGNALS.items():
        row = poses[pose]
        need({k: v for k, v in row.items() if k != "retina"} == {"file": f"{P}{pose}-1x.png", "frames": frames, "interval": interval},
             f"{pose} is the V15 {frames}-frame signal")
        need(PINNED[row["file"]][1:3] == (frames * cell, 256), f"{pose} is {frames} cells of {cell}x256 px at 1x")
        need(row["retina"].get("scale") == 2 and "variants" not in row["retina"], f"{pose} retina is a scale 2 strip")
        segments_tile(row["retina"]["file"], frames, cell, f"{P}{pose}")
    need(poses["working"].get("renderScale") == 0.75 and poses["idle"].get("renderScale") == 1.0, "pack-owned scales are V14's")
    for name, (digest, width, height, size) in PINNED.items():
        data = read(name)
        need(data is not None, f"{name} is missing")
        need(png(data, name) == (width, height, 6), f"{name} must be an RGBA PNG {width}x{height}")
        need(len(data) == size, f"{name} is {len(data)} bytes, pinned {size}")
        need(hashlib.sha256(data).hexdigest() == digest, f"{name} drifted from the approved V15 bytes")
    need(set(referenced) == set(PINNED), "the map names exactly the pinned files")
    new = {n for n in PINNED if n.startswith(P)}
    need({n for n in listing if n.startswith(P)} == new, "no orphan V15 file ships")
    need(not any(n.endswith("-v15.png") for n in new), "no V15 file reuses the -v15.png suffix of the older strips")
    lowered = [n.lower() for n in listing]
    need(len(set(lowered)) == len(lowered), "two DefaultPet files differ only by case (one name on a Mac disk)")
    need(not any(n.startswith("session-pet-windu-v14-timing-v2-") or n.startswith("session-pet-windu-v1-5-") for n in listing),
         "V14's cast layers and the superseded V1.5 bake no longer ship (installed copies are never deleted)")
    for name, (digest, frames) in RETAINED_V14.items():
        data = read(name)
        need(data is not None and hashlib.sha256(data).hexdigest() == digest, f"retained V14 strip {name} drifted or is missing")
        need(f'("{name}", {frames}),' in models, f"the upgrade does not recognize an installed V14 {name} at {frames} frames")
    need("for pose in [PetSpritePose.working, .duel, .trio, .swarm] where only?.contains(pose) ?? true {" in models,
         "Session 1 casts load (loadRotations covers working)")
    need(int(re.search(r"petDefaultArtGeneration = (\d+)", controller).group(1)) >= 23, "art generation 23 runs the V15 upgrade once")
    need("PetSpriteStore.loadPoseFrames(in: directory, stateMap: petStateMap, displayScale: petDisplayScale," in controller
         and controller.count("PetSpriteStore.loadRotations(in: directory, displayScale: scale, only: [want])") == 2
         and "let scale = petDisplayScale" in controller,
         "the live pet picks its strips by the pet window's display scale")
    # Memory gate (0.5.328): casts decode for the pose on screen only, the old pose's are released first, a hidden pet
    # holds none, and loadPetSprite itself decodes no cast.
    ensure = controller.split("func ensurePetRotation(for pose: PetSpritePose", 1)[1].split("\n    }\n", 1)[0]
    need("if !petSpriteKit.rotations.isEmpty { petSpriteKit.rotations = [:] }" in ensure
         and ensure.index("petSpriteKit.rotations = [:]") < ensure.index("loadRotations("),
         "the previous pose's casts are released before the next pose decodes")
    load = controller.split("    func loadPetSprite() {", 1)[1].split("\n    }\n", 1)[0]
    need("loadRotations(" not in load and "rotations: [:])" in load and "ensurePetRotation(for: petSpritePose)" in load,
         "loading the pet decodes no casts beyond the pose on screen")
    need("model.ensurePetRotation(for: show ? model.petSpritePose : .idle)" in pet, "the presenter keeps the casts on the pose on screen")
    need(pet.count("model?.setPetDisplayScale(panel.backingScaleFactor)") == 2 and "func windowDidChangeBackingProperties(" in pet
         and "func windowDidChangeScreen(" in pet, "moving the pet between a 1x and a 2x screen re-picks its strips")
    need("guard let row = PetRetinaRow(value), displayScale >= CGFloat(row.scale) else { return nil }" in models,
         "a retina strip is chosen only on a display of at least its scale")
    refresh = models.split("static func refreshRecognizedBundledDefault(", 1)[1].split("static func remove(from", 1)[0]
    need("removeItem" not in refresh and "removeAll" not in refresh, "the stock upgrade never deletes a file")
    need("retinas: retinaRows," in refresh and "sameRetina(pose)" in refresh, "the upgrade lands the retina strips and requires them to be current")
    return len(PINNED)


def main() -> None:
    root = pathlib.Path(next((a for a in sys.argv[1:] if a != "-v"), "."))
    folder = root / "Resources/DefaultPet"
    map_bytes = (folder / "session-pet-states.json").read_bytes()
    listing = {p.name for p in folder.iterdir() if p.is_file()}
    release = (root / "scripts/build-release.sh").read_text()
    models = (root / "Sources/Models.swift").read_text()
    controller = (root / "Sources/ControllerModel.swift").read_text()
    pet = (root / "Sources/SessionPet.swift").read_text()
    cache: dict[str, bytes | None] = {}

    def read(name: str) -> bytes | None:
        if name not in cache:
            path = folder / name
            cache[name] = path.read_bytes() if path.is_file() else None
        return cache[name]

    base = (map_bytes, read, listing, release, models, controller, pet)
    pinned = validate(*base)

    def edited(edit: Callable[[dict], None]) -> bytes:
        state = json.loads(map_bytes)
        edit(state)
        return (json.dumps(state, indent=2, sort_keys=True) + "\n").encode()

    def flip(name: str) -> Callable[[str], bytes | None]:
        return lambda n: (read(n)[:-1] + bytes([read(n)[-1] ^ 1])) if n == name else read(n)

    def resize(name: str) -> Callable[[str], bytes | None]:
        return lambda n: read(n)[:16] + struct.pack(">I", PINNED[name][1] + 1) + read(n)[20:] if n == name else read(n)

    def with_(**kw):
        order = ["map_bytes", "read", "listing", "release", "models", "controller", "pet"]
        args = dict(zip(order, base))
        args.update(kw)
        return tuple(args[k] for k in order)

    swarm_s2 = P + "swarm-b-body-2x-s2.png"
    mutants = [
        ("a 1x cast layer's bytes change", with_(read=flip(P + "swarm-c-entry-1x.png"))),
        ("a retina segment's bytes change", with_(read=flip(swarm_s2))),
        ("a Session 1 retina strip's width changes", with_(read=resize(P + "working-b-full-2x.png"))),
        ("a signal strip's bytes change", with_(read=flip(P + "attention-2x.png"))),
        ("an ambient strip gains a byte", with_(read=lambda n: read(n) + b"\0" if n == "session-pet-waiting-release-v1.png" else read(n))),
        ("a retina segment is missing", with_(read=lambda n: None if n == swarm_s2 else read(n), listing=listing - {swarm_s2})),
        ("the map's bytes change (same content, other indent)", with_(map_bytes=json.dumps(json.loads(map_bytes), indent=4).encode())),
        ("Session 1 loses a cast", with_(map_bytes=edited(lambda s: s["poses"]["working"]["rotation"]["variants"].pop()))),
        ("Session 1 loses its rotation", with_(map_bytes=edited(lambda s: s["poses"]["working"].pop("rotation")))),
        ("a fourth trio cast", with_(map_bytes=edited(lambda s: s["poses"]["trio"]["rotation"]["variants"].append(
            dict(s["poses"]["trio"]["rotation"]["variants"][0], id="trio-d"))))),
        ("a rotation on idle", with_(map_bytes=edited(lambda s: s["poses"]["idle"].__setitem__("rotation", s["poses"]["duel"]["rotation"])))),
        ("a layer named in a subfolder", with_(map_bytes=edited(lambda s: s["poses"]["duel"]["rotation"]["variants"][0].__setitem__(
            "file", "rotation/v15/duel-a-full.png")))),
        ("the swarm handoff drifts", with_(map_bytes=edited(lambda s: s["poses"]["swarm"]["rotation"].__setitem__("handoffFrame", 54)))),
        ("attention goes back to V12's 13 frames", with_(map_bytes=edited(lambda s: s["poses"]["attention"].update(
            file="session-pet-attention-retime-v12-v1.png", frames=13, interval=0.14)))),
        ("a seeded rotation ships", with_(map_bytes=edited(lambda s: s["poses"]["duel"]["rotation"].__setitem__("seed", 7)))),
        ("the retina segments swap order", with_(map_bytes=edited(lambda s: s["poses"]["swarm"]["retina"]["variants"][1]["bodyFile"].reverse()))),
        ("a retina segment is dropped from the map", with_(map_bytes=edited(lambda s: s["poses"]["swarm"]["retina"]["variants"][2]["entryFile"].pop()))),
        ("retina casts in another order", with_(map_bytes=edited(lambda s: s["poses"]["duel"]["retina"]["variants"].reverse()))),
        ("retina declared at scale 3", with_(map_bytes=edited(lambda s: s["poses"]["trio"]["retina"].__setitem__("scale", 3)))),
        ("a retina strip on idle", with_(map_bytes=edited(lambda s: s["poses"]["idle"].__setitem__("retina", s["poses"]["error"]["retina"])))),
        ("done loses its retina strip", with_(map_bytes=edited(lambda s: s["poses"]["done"].pop("retina")))),
        ("an orphan V15 file ships", with_(listing=listing | {P + "duel-d-full-1x.png"})),
        ("a new name collides by case", with_(listing=listing | {(P + "duel-a-full-1x.png").upper()})),
        ("a V14 cast layer ships again", with_(listing=listing | {"session-pet-windu-v14-timing-v2-duel-a-full.png"})),
        ("the superseded V1.5 bake ships", with_(listing=listing | {"session-pet-windu-v1-5-duel-a-full.png"})),
        ("a retained V14 strip changes", with_(read=flip("session-pet-trio-v13.png"))),
        ("the upgrade forgets V14 Session 1", with_(models=models.replace('("session-pet-working-v13.png", 46),', "", 1))),
        ("the loader drops Session 1 casts", with_(models=models.replace(
            "for pose in [PetSpritePose.working, .duel, .trio, .swarm] where", "for pose in [PetSpritePose.duel, .trio, .swarm] where", 1))),
        ("every cast decodes at once", with_(controller=controller.replace(
            "PetSpriteStore.loadRotations(in: directory, displayScale: scale, only: [want])",
            "PetSpriteStore.loadRotations(in: directory, displayScale: scale)", 1))),
        ("the old pose is kept while the next decodes", with_(controller=controller.replace(
            "        if !petSpriteKit.rotations.isEmpty { petSpriteKit.rotations = [:] }\n", "", 1))),
        ("loading the pet decodes every cast again", with_(controller=controller.replace(
            "cinematic: cinematic, rotations: [:])", "cinematic: cinematic, rotations: PetSpriteStore.loadRotations(in: directory))", 1))),
        ("a hidden pet keeps its casts", with_(pet=pet.replace(
            "model.ensurePetRotation(for: show ? model.petSpritePose : .idle)", "model.ensurePetRotation(for: model.petSpritePose)", 1))),
        ("the art generation stays at 22", with_(controller=re.sub(r"petDefaultArtGeneration = \d+", "petDefaultArtGeneration = 22", controller))),
        ("the live pet ignores the display scale", with_(controller=controller.replace(
            "let scale = petDisplayScale", "let scale: CGFloat = 1", 1))),
        ("retina chosen on a 1x display", with_(models=models.replace(
            "displayScale >= CGFloat(row.scale) else { return nil }", "displayScale >= 1 else { return nil }", 1))),
        ("a screen change does not re-pick", with_(pet=pet.replace("func windowDidChangeScreen(", "func windowDidChangeScreenIgnored(", 1))),
        ("the upgrade drops the retina strips", with_(models=models.replace("                retinas: retinaRows,\n", "", 1))),
        ("the upgrade deletes a file", with_(models=models.replace(
            "            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)\n            for story in stories {",
            "            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)\n"
            "            try? fileManager.removeItem(at: directory)\n            for story in stories {", 1))),
        ("the release copies subfolders only", with_(release=release.replace('"$ROOT/Resources/DefaultPet/"*.png ', ""))),
    ]
    for name, args in mutants:
        # A mutant must land: at least one input differs from the real tree (a read mutant swaps the reader for one
        # that changes a file that exists), or a check that cannot fail would be reported as a catch.
        changed = [i for i, (a, b) in enumerate(zip(args, base)) if a is not b and a != b]
        landed = changed != [] and all(i != 1 or any(args[1](n) != read(n) for n in PINNED.keys() | RETAINED_V14.keys())
                                       for i in changed)
        if not landed:
            sys.exit(f"jedi-v15 pins: mutant '{name}' did not land (it changes nothing the checks read)")
        structural = args[0] != map_bytes and "other indent" not in name
        try:
            validate(*args, pin_map=not structural)
        except Fail as caught:
            if "-v" in sys.argv:
                print(f"  caught {name}: {caught}")
            continue
        sys.exit(f"jedi-v15 pins: mutant '{name}' was not caught")
    print(f"jedi-v15 pins: {pinned} files pinned (map {MANIFEST_SHA[:8]}), 1x and retina, 4 Session 1 casts and 3 on duel, "
          f"trio and swarm, 4 retained V14 strips and the upgrade and display-scale wiring; {len(mutants)} mutants each landed and caught")


if __name__ == "__main__":
    main()
