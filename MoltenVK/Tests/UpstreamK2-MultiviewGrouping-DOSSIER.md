# K2 : regroupement des passes multiview, dossier de proposition upstream (30 septembre 2026)

Dossier finalisé après la validation d'Astra (K1/K2 preuves autonomes suffisantes pour la tranche 1). Aucune
publication : push et PR restent une décision de l'utilisateur. K1 a son propre dossier
(`UpstreamK1-DynamicTopologyFans-DOSSIER.md`).

**Aucune preuve GPU multiview n'accompagne ce correctif.** La preuve est un test hôte sur le code extrait ; Astra l'a
jugée suffisante pour proposer ces corrections algorithmiques.

## 1. Défauts

1. **Masques clairsemés sans rendu en couches.** Quand `canUseInstancingForMultiview()` est faux, chaque passe Metal
   rend une seule vue active. `MVKDevice::getFirstViewIndexInMetalPass` parcourait les groupes de vues et décrémentait
   l'indice de passe à l'intérieur de chaque groupe, ce qui sautait les trous entre groupes : pour le masque `0b101`,
   la passe 0 commençait à la vue 3 au lieu de 0.
2. **Décalage hors borne.** `mvkGetNextViewMaskGroup` décalait un `1` signé de la position de fin courante ; avec la
   vue 31 active, la boucle atteignait un décalage de 32, comportement indéfini. MoltenVK annonce
   `maxMultiviewViewCount = 32`, la vue 31 est donc valide.

Portée : `canUseInstancingForMultiview()` vaut `_metalFeatures.layeredRendering` (`MVKDevice.h:430`), vrai sur les
familles Mac1 et Apple5 et plus (`MVKDevice.mm:2508-2518`, `2600-2602`). Le défaut 1 ne touche donc que les GPU sans
rendu en couches (iOS et tvOS antérieurs à Apple5), où le chemin multipasse est pris ; il n'est pas atteignable sur les
Mac Apple Silicon disponibles ici. Le défaut 2 touche aussi le chemin en couches, qui appelle `mvkGetNextViewMaskGroup`.

## 2. Correctif

Base : upstream `a63d4863`. Branche finale locale `claude/k2-multiview-grouping`, un commit
`73b461c523bd817c33fc0296aa000236808c9927` :

- `MVKDevice.mm` : la première vue de la passe N est le bit le plus bas qui reste après avoir effacé N vues actives ;
- `MVKRenderPass.mm` : décalages non signés, et arrêt de la boucle dès que le masque est vide ;
- `Docs/Whats_New.md` : une ligne sous MoltenVK 1.4.3.

**Correspondance avec les preuves du 30 septembre.** La branche de preuve `claude/upstream-k2-multiview-grouping`
(`9a292014`) reste intacte. `73b461c5` n'en diffère que par la ligne `Whats_New.md` : `git diff 9a292014 73b461c5 --
':!Docs/Whats_New.md'` est vide (`final/k2-evidence-to-final.diff`). Le test hôte a été relancé sur l'arbre final.

## 3. Test hôte

`MoltenVK/Tests/MultiviewGroupingTests.cpp` compile, telles qu'extraites du code source, les fonctions
`mvkGetNextViewMaskGroup`, `MVKDevice::getMultiviewMetalPassCount`, `getFirstViewIndexInMetalPass`,
`getViewCountInMetalPass` et `MVKRenderSubpass::getViewMaskGroupForMetalPass`, avec des stubs pour le device et la
passe, sous AddressSanitizer et UndefinedBehaviorSanitizer. Il compare nombre de passes, première vue, nombre de vues
et masque de groupe à une référence, avec et sans rendu en couches : tous les masques sur 16 bits, des masques
clairsemés et à bit haut sur 32 bits, 4 096 masques pseudo-aléatoires.

Lanceur autonome `MoltenVK/Tests/MultiviewGroupingRepro/run.sh` et `README.md` en anglais (commit du fork `b1626370`),
sur un checkout MoltenVK quelconque ; il lance le test complet puis les masques `0x5`, `0x80000000` et `0xffffffff`
seuls :

```
bash run.sh <checkout MoltenVK> <dossier de sortie>
```

Publié avec `MultiviewGroupingTests.cpp`, à la demande de l'utilisateur, en gist public :
https://gist.github.com/carbonimax/20e5ff2c1083153ca0d63f6ac2f1083a (révision `6ad8a659`, trois fichiers identiques
au dépôt, vérifié par clonage). Lancé depuis le dossier plat du gist, il est rouge sur `a63d4863` et vert sur
`73b461c5`, avec un code extrait identique aux séries `final/` (`build/astra/upstream-k2-a63d4863/repro/`,
`EVIDENCE-K2-REPRO.sha256`, 20 fichiers). Le premier lanceur, `run-pervertex-multiview-tests.sh`, reste dans le fork
pour les preuves déjà enregistrées.

## 4. Résultats

| Code testé | Test complet | `0x5` | `0x80000000`, `0xffffffff` |
|---|---|---|---|
| `a63d4863` | exit 1 : `mask=5 layered=0 pass=0 actual={3,1} expected={0,1}` | exit 1 | exit 134 : UBSan « shift exponent 32 is too large » |
| final `73b461c5` | exit 0 : 901 970 vérifications | exit 0 | exit 0 |

Les mêmes résultats avaient été obtenus le 30 septembre sur `a63d4863` et `9a292014` (`EVIDENCE-K2.sha256`).

Chaque hunk est rouge séparément sur la base. Le diff du code extrait entre base et correctif est exactement le patch
(`inc-before-after.diff`) ; le code extrait de `73b461c5` est identique à celui de `9a292014`.

Compilation : `73b461c5` compile avec `MVK_USE_METAL_PRIVATE_API` désactivé (`975c9bfe…`) et activé (`9e68aab0…`),
avec le seul avertissement déjà présent sur la base. Chaque bibliothèque porte comme `mvkRevString` le commit de son
checkout (section 7). Le test hôte ne dépend pas de la bibliothèque : l'identité avec `9a292014` repose sur le diff
source et sur la relance du test.

## 5. Exigences de contribution (README upstream, section *Contributing*)

| Exigence | État |
|---|---|
| CLA (cla-assistant) à la première PR | Action de l'utilisateur, non faite. |
| En-tête de licence des nouveaux fichiers | Sans objet : la branche ne crée aucun fichier. Le test hôte reste dans le fork. |
| Pas de validation Vulkan superflue | Respecté : aucune validation ajoutée. |
| Gestion mémoire Objective-C | Sans objet. |
| Style de code | Tabulations et style des fichiers touchés ; `git diff --check` propre. |
| `Docs/Whats_New.md` | Ligne ajoutée sous MoltenVK 1.4.3 ; conflit trivial avec celle de K1 si les deux deviennent des PR. |
| CI | Non exécutée localement (matrice Xcode macOS/iOS et CMake) ; seul l'équivalent CMake macOS arm64 Debug, privé désactivé et activé, a tourné. |

## 6. Limites

1. **Pas de preuve GPU multiview.** Le chemin multipasse corrigé n'est pris que sans rendu en couches, sur des GPU
   iOS/tvOS antérieurs à Apple5 dont nous ne disposons pas ; le chemin en couches avec la vue 31 n'a pas tourné non
   plus.
2. Le test hôte vérifie les fonctions extraites contre une référence ; il ne vérifie pas leurs appelants (encodage des
   passes, clear, load et store des attachements).
3. Les Mac Intel ne seront pas testés ; M1 et M2 restent pour la qualification finale.

## 7. Preuves (`build/astra/upstream-k2-a63d4863/`)

- `EVIDENCE-K2.sha256` (19 fichiers) : test hôte rouge et vert du 30 septembre, sur `9a292014`.
- `final/EVIDENCE-K2-FINAL.sha256` (21 fichiers, sha256 `300b4b7b…`) : `build-upstream.sh` (lancé depuis le
  checkout), `mvk-rev-string.txt`, `k2-final-patches/`, `k2-evidence-to-final.diff`, `inc-before-after.diff`,
  provenance et journal de `lib-final` et `lib-final-private-api`, test hôte sur la base (`host-before/`) et sur l'arbre
  final (`host-final/`).
- `final-superseded-rev/EVIDENCE-K2-FINAL.sha256` (13 fichiers) : première série finale, même code, conservée. Ses
  bibliothèques avaient été configurées hors de leur checkout et portaient une `mvkRevString` fausse (`0ddd63d3`, un
  commit du fork) ; `mvk-rev-string.txt` liste les révisions gravées de toutes les bibliothèques.

## 8. Brouillon de description de PR (anglais)

> **Fix multiview pass grouping for sparse and high view masks**
>
> When layered rendering is unavailable, each Metal pass renders one enabled view. `getFirstViewIndexInMetalPass`
> walked the view groups and decremented the pass index inside each group, so it skipped the gaps between groups: for
> view mask `0b101`, pass 0 started at view 3 instead of view 0. The first view of pass N is now the lowest enabled
> view left after clearing N enabled views.
>
> `mvkGetNextViewMaskGroup` shifted a signed `1` by the running end position. With view 31 enabled the loop reached a
> shift by 32, which is undefined behavior. The shifts are now unsigned and the loop stops once the mask is empty.
>
> Testing: a host test (https://gist.github.com/carbonimax/20e5ff2c1083153ca0d63f6ac2f1083a) compiles these functions as extracted from the source, with stubs for the device and render
> pass, under AddressSanitizer and UndefinedBehaviorSanitizer. It checks the pass count, first view, view count and
> group mask of every pass against a reference, with and without layered rendering, for every 16-bit mask, sparse and
> high-bit 32-bit masks, and 4096 pseudo-random masks (901,970 checks). Before this change, mask `0x5` gives the wrong
> first view and masks `0x80000000` and `0xffffffff` trigger the shift by 32; after it, all checks pass. No GPU
> multiview test was run: the multipass path needs a GPU without layered rendering. Built with CMake (Debug, arm64),
> with `MVK_USE_METAL_PRIVATE_API` off and on.
>
> 🤖 Generated with [Claude Code](https://claude.com/claude-code)
