# K1 : conversion des fans avec topologie dynamique, dossier de proposition upstream (30 septembre 2026)

Dossier finalisé après la validation d'Astra (K1/K2 preuves autonomes suffisantes pour la tranche 1). K2 a son propre
dossier (`UpstreamK2-MultiviewGrouping-DOSSIER.md`).

**PR : [KhronosGroup/MoltenVK#2851](https://github.com/KhronosGroup/MoltenVK/pull/2851)**, ouverte le 30 septembre
2026 avec l'autorisation de l'utilisateur, depuis `carbonimax:fix-dynamic-topology-fans` (commit `aa9133c5`, sans
rebase ; la branche fusionnait sans conflit sur `main` à `52aa21f5`). K2 est la PR #2852.

## 1. Défaut

MoltenVK dessine les triangle fans en les convertissant en triangles indexés. Les quatre chemins de dessin de
`MVKCmdDraw.mm` (direct, indexé, indirect, et les ajustements de l'indexé indirect) décidaient de la conversion d'après
la topologie de création du pipeline (`MVKGraphicsPipeline::getVkPrimitiveTopology()`), et ignoraient donc une
topologie fixée par `vkCmdSetPrimitiveTopology`. Le défaut a deux sens :

- un pipeline créé en liste ou en bande de triangles dessine un fan dynamique comme une liste ;
- un pipeline créé en fan fait passer une liste ou une bande dynamique par la conversion en fan.

## 2. Correctif

Base : upstream `a63d4863` (upstream/main du 24 septembre 2026). Branche finale locale
`claude/k1-dynamic-topology-fans` :

| Commit | Contenu |
|---|---|
| `96d67379157cd78747f085c532127f412da662c4` | L'état de rendu garde la topologie Vulkan (`MVKRenderStateData::vkPrimitiveTopology`), statique depuis le pipeline ou dynamique ; `getPrimitiveTopology()` sur l'état de l'encodeur. |
| `aa9133c5a527281fb9626b4db5abbf7465a1cf04` | Les quatre sites lisent la topologie effective ; l'accesseur `getVkPrimitiveTopology()` du pipeline, resté sans appelant, est supprimé ; une ligne dans `Docs/Whats_New.md`. |

Six fichiers, tous existants : `MVKStateTracking.h`, `MVKPipeline.mm`, `MVKCmdRendering.mm`,
`MVKCommandEncoderState.h`, `MVKCmdDraw.mm`, `MVKPipeline.h`, plus `Docs/Whats_New.md`. Un grep à `430d544f` confirme
que ces quatre sites étaient les seuls à décider du fan d'après la topologie statique ; `MVKPipeline.mm:892` n'émet
qu'un avertissement sur le redémarrage de primitive et couvre déjà la topologie dynamique.

**Correspondance avec les preuves du 30 septembre.** La branche de preuve `claude/upstream-k1-dynamic-fans`
(`96d67379`, `430d544f`) reste intacte. Le premier commit est le même. Le second diffère de `430d544f` par le message
(reformulé pour couvrir les deux sens), la suppression de l'accesseur et la ligne `Whats_New.md`
(`final/k1-evidence-to-final.diff`). Le code ayant changé, le vert a été refait sur l'arbre final (section 4).

## 3. Reproducteur autonome

`MoltenVK/Tests/DynamicTopologyFanRepro/` (commit du fork `5ea50d10`) : `DynamicTopologyFan.mm`, deux shaders
(`dynamic-topology-fan.vert`, `dynamic-topology-fan.frag`), `run.sh`, `README.md` en anglais. Publié tel quel, à la
demande de l'utilisateur, en gist public : https://gist.github.com/carbonimax/6737e3169ba9cc2254e5343a5111934d
(révision `f6c2d258`, cinq fichiers identiques au dépôt, vérifié par clonage). Aucune extension barycentrique, aucune
dépendance au fork :

```
bash run.sh <libMoltenVK.dylib> <Vulkan-Headers/include> <dossier de sortie>
```

Douze cas : trois classes (`triangles` : pipeline liste qui dessine liste, bande, fan ; `triangles-fan-first` :
pipeline fan qui dessine fan, bande, liste ; `lines` : témoin sans fan) × quatre formes (direct, indexé, indirect,
indexé indirect), sous validation Metal API et GPU. Pour chaque cas, l'image du pipeline dynamique doit égaler celle
des pipelines statiques, différer du pipeline dynamique gardé à sa première topologie, et le nombre d'invocations du
VS doit être égal.

Le reproducteur est l'oracle de `0ddd63d3` : programme identique aux noms de fichiers de shaders près, et SPIR-V
identique bit à bit (vert `5517c26e…`, frag `e3eb5a94…`, `final/spirv-identity.txt`).

## 4. Résultats (M4 Pro, macOS 27.2, Xcode 27.1, CMake Debug arm64, API privée désactivée)

| Classe × 4 formes | `a63d4863` (`c842f473…`) | final `aa9133c5` (`c236ef8e…`) |
|---|---|---|
| `triangles` | 4/4 FAIL : 362 px, image égale à la première topologie gardée, invocations 24 contre 30 | 4/4 PASS : 0 px, 30 = 30 |
| `triangles-fan-first` | 4/4 FAIL : 730 px, invocations 54 contre 30 | 4/4 PASS : 0 px, 30 = 30 |
| `lines` | 4/4 PASS | 4/4 PASS |

Compilation : `aa9133c5` compile avec `MVK_USE_METAL_PRIVATE_API` désactivé (`c236ef8e…`) et activé (`fad271f1…`), avec
le seul avertissement déjà présent sur la base (`MVKConfigMembers.def:56`). Chaque bibliothèque porte comme
`mvkRevString` le commit de son checkout (section 7). **Les deux builds réussissent, mais les essais GPU (reproducteur
rouge et vert) n'ont tourné qu'avec `MVK_USE_METAL_PRIVATE_API` désactivé**, la valeur par défaut ; la configuration
activée n'est que compilée.

## 5. Exigences de contribution (README upstream, section *Contributing*)

| Exigence | État |
|---|---|
| CLA (cla-assistant) | Réussi sur #2851 (contrôle `license/cla`). |
| En-tête de licence des nouveaux fichiers | Sans objet : la branche ne crée aucun fichier. Le reproducteur reste dans le fork, sous l'en-tête du fork. |
| Pas de validation Vulkan superflue | Respecté : aucune validation ni erreur ajoutée. |
| Gestion mémoire Objective-C | Sans objet : aucun objet Objective-C créé. |
| Style de code | Tabulations et style des fichiers touchés ; `git diff --check` propre. |
| `Docs/Whats_New.md` | Ligne ajoutée sous MoltenVK 1.4.3, comme le font les contributeurs récents. Elle entrera en conflit trivial avec celle de K2 si les deux deviennent des PR. |
| CI (`.github/workflows/CI.yml`) | CI de la PR : 7 builds réussis (Xcode all, macos, ios, macos-privateapi, Xcode 15.0.1 macos, CMake Debug et Release), `Release` (publication des artefacts) ignoré. Elle construit le commit de fusion avec `main` (`52aa21f5`, nouveau pin SPIRV-Cross) : preuve de compilation, sans nouvelle preuve GPU. Avant la PR, non exécutée localement : matrice Xcode macOS/iOS (`make` après `fetchDependencies`) et CMake. Seul l'équivalent CMake macOS arm64 Debug, privé désactivé et activé, a tourné ici. Les dépendances Xcode du fork sont construites à un autre pin de SPIRV-Cross et ne peuvent pas servir de preuve. |

## 6. Limites

1. GPU testé : Apple M4 Pro seulement. Les passages M1 et M2 restent pour la qualification finale ; les Mac Intel ne
   seront pas testés, et la proposition doit le dire.
2. Avec les six sommets de l'oracle, bande et liste produisent la même image : dans la classe `triangles`, le contrôle
   « diffère de la première topologie gardée » ne distingue que l'étape fan. `lines` est le témoin liste/bande.
3. Aucun cas CTS n'a été exécuté sur la base upstream pour ce correctif.
4. Essais GPU avec `MVK_USE_METAL_PRIVATE_API` désactivé seulement ; avec l'API privée, le correctif est compilé, pas
   exécuté. Le site des ajustements de l'indexé indirect voisine un bloc `#if MVK_USE_METAL_PRIVATE_API` qu'il ne
   modifie pas.

## 7. Preuves (`build/astra/upstream-k1-a63d4863/`)

- `EVIDENCE-K1.sha256` (39 fichiers) : oracle rouge et vert du 30 septembre, sur `430d544f`.
  Les `INPUTS.sha256` de `oracle-before/` et `oracle-after/` nomment l'arbre du fork à `0ddd63d3` :
  `DynamicTopologyFanTests.mm` y est devenu `DynamicTopologyFanRepro/DynamicTopologyFan.mm` (identique aux deux lignes de
  noms de shaders près) et `run-dynamic-topology-fan-tests.sh` a été retiré par `5ea50d10`. Un `shasum -c` lancé dans
  ces dossiers signale donc ces deux chemins comme absents ; les fichiers restent dans l'historique à `0ddd63d3`.
- `final/EVIDENCE-K1-FINAL.sha256` (40 fichiers, sha256 `d9c78b56…`) : `build-upstream.sh` (lancé depuis le
  checkout, argument CMake supplémentaire), `mvk-rev-string.txt`, `k1-final-patches/`, `k1-evidence-to-final.diff`,
  `spirv-identity.txt`, provenance et journal de `lib-base`, `lib-final` et `lib-final-private-api`, reproducteur rouge
  (`repro-before/`, sur `lib-base`) et vert (`repro-final/`).
- `final-superseded-rev/EVIDENCE-K1-FINAL.sha256` (37 fichiers) : première série finale, même code, conservée. Le CMake
  de MoltenVK grave `git rev-parse --short HEAD` du dossier de configuration dans `mvkRevString` ; ces bibliothèques,
  comme `lib-before` (`59623772`, un commit du fork), avaient été configurées hors de leur checkout et portaient une
  révision fausse. `mvk-rev-string.txt` liste les révisions gravées de toutes les bibliothèques. Les résultats sont
  identiques d'une série à l'autre.

## 8. Brouillon de description de PR (anglais)

> **Convert triangle fans from the effective primitive topology**
>
> MoltenVK draws triangle fans by converting them to indexed triangles, but the draw paths decided whether to convert
> from the topology the pipeline was created with. With `VK_DYNAMIC_STATE_PRIMITIVE_TOPOLOGY`, a pipeline created as a
> triangle list or strip drew a dynamic triangle fan as a triangle list, and a pipeline created as a triangle fan drew
> a dynamic triangle list or strip through the fan conversion.
>
> The render state now keeps the Vulkan topology next to the Metal primitive type, which cannot tell a fan from a
> list, and the four draw paths read the effective topology from the encoder state. The pipeline accessor they used
> has no caller left and is removed.
>
> Testing: a standalone reproducer (https://gist.github.com/carbonimax/6737e3169ba9cc2254e5343a5111934d) draws each topology of a class through one dynamic pipeline and compares
> the image and the vertex shader invocation count with one static pipeline per topology, in direct, indexed,
> indirect and indexed indirect forms, under Metal API and GPU validation. Before this change, the 8 triangle cases
> fail and the 4 line cases pass; after it, all 12 pass. Tested on Apple M4 Pro, macOS 27.2, with MoltenVK built with
> CMake (Debug, arm64) and `MVK_USE_METAL_PRIVATE_API` off. The change also builds with `MVK_USE_METAL_PRIVATE_API` on,
> but that configuration was not run on the GPU. Not tested on Intel Macs.
>
> 🤖 Generated with [Claude Code](https://claude.com/claude-code)
