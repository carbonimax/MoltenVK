# Bornes de `DrawIndirectCount` pour PerVertexKHR indirect : analyse CPU

Point 2 de la clôture de PerVertexKHR, option (a) : contrat restreint, extension fermée par défaut. La demande d'Astra est de partir du code actuel, d'établir les bornes pour tout `DrawIndirectCount` légal et de proposer un traitement cohérent. Deux choses sont exclues : un plafond privé, et une réduction silencieuse de `maxDrawIndirectCount` pour tous les dessins de MoltenVK.

Analyse sur `MoltenVK-pervertex-generic`, runtime `a3f02d1c`. Aucun code n'est modifié.

## 1. Ce que fait le code actuel

La formule notée dans le plan et dans `MoltenVK-indirect-continuation-r2/WORKLOG.md` (« `1024 + 20 × maxDrawCount` octets dans un seul buffer de plan ») est **périmée**. Aujourd'hui, `recordPerVertexIndirectDraw()` (`MVKCommandBuffer.mm:523-560`) réserve séparément deux choses :
- **Un plan de taille fixe** : `1024` octets, plus `(pas de balayage + 3) × 256` octets avec le redémarrage de primitives. Cette taille est calculée pour le plafond d'identifiants `UINT32_MAX` et ne dépend pas du nombre de dessins.
- **Un instantané par commande**, quand `drawCount > 1` : `drawCount × 16` octets, ou `× 20` pour les dessins indexés, c'est-à-dire la commande Vulkan de chaque dessin, figée en phase 0. Un dessin unique fige sa commande dans le plan (mots 48 à 52).

Pour `vkCmdDrawIndirectCount`, `drawCount` est `maxDrawCount`, car le compte réel n'est connu que du GPU.

## 2. Les bornes, pour tout dessin légal

**B1 : l'instantané tient toujours dans un MTLBuffer.**
- Vulkan impose, pour `vkCmdDrawIndirect` et `vkCmdDrawIndexedIndirect` si `drawCount > 1`, et pour les variantes `…Count` si `maxDrawCount ≥ 1` : `stride × (n − 1) + offset + sizeof(commande) ≤ taille du buffer`, avec `stride ≥ sizeof(commande)` (16 ou 20).
- Donc `n × sizeof(commande) ≤ stride × (n − 1) + sizeof(commande) ≤ taille − offset`.
- Dans MoltenVK, un `VkBuffer` ne dépasse pas `maxMTLBufferSize` : `maxBufferSize` et `maxMemoryAllocationSize` valent cette limite (`MVKDevice.mm:859`, `970`, `1079`), et la liaison d'un buffer à une mémoire plus grande est refusée (`MVKDeviceMemory.mm:140`).
- L'instantané fait donc au plus l'étendue lue dans le buffer d'arguments, et le refus à l'enregistrement (`MVKCommandBuffer.mm:547`) **n'est jamais atteint en usage valide**.
- Pire cas M4 Pro (`maxMTLBufferSize = 41 747 087 360`) : 2 609 192 960 dessins non indexés, ou 2 087 354 368 indexés. L'instantané fait alors 41,7 Go.

**B2 : la grille de la phase 0 tient.** La phase 0 envoie `⌈n / largeur⌉` groupes (`MVKCmdDraw.mm:1159`). Au pire légal, avec une largeur de 32, cela fait 81,5 millions de groupes, sous la limite que MoltenVK annonce (`maxComputeWorkGroupCount` = 2³⁰, soit 1 073 741 824, `MVKDevice.mm:3167`). La limite propre de Metal n'est pas vérifiée ici.

**B3 : le plan ne dépend pas de `n`.** Voir le § 1.

**B4 : l'arithmétique ne déborde pas.** Le noyau adresse arguments et instantané en `ulong` (`MVKCommandPipelineStateFactoryShaderSource.h`, phase 0). Côté CPU, tout est en `uint64` (`MVKCommandBuffer.mm:546`), et `mvkSizePerVertexIndirectReplay()` refuse un compte figé qui dépasserait l'instantané (`MVKPerVertexScratch.h:43`).

**B5 : la mémoire est proportionnelle à `maxDrawCount`, pas au compte réel.**
- L'instantané double au plus l'étendue du buffer d'arguments, une fois par passe multiview.
- Si l'allocation échoue, `vkQueueSubmit` rend `VK_ERROR_OUT_OF_DEVICE_MEMORY` avant toute exécution (`MVKCommandBuffer.mm:620`). C'est un résultat permis par Vulkan, pas un refus d'un dessin légal.
- Le réduire au compte réel demande de connaître ce compte avant la soumission. C'est la continuation, exclue par l'option (a).

**B6 : l'encodage du rejeu est proportionnel au compte réel. C'est la seule vraie limite d'échelle.**
- Après la phase 0, le CPU encode, pour chaque dessin figé, une planification, des tables, une capture et un dessin de rejeu (`MVKCmdDraw.mm:1191`, boucle sur `frozenDraws`). Cela fait au moins un encodeur de calcul et un encodeur de rendu par dessin, dessins vides compris.
- Aucune borne de buffer ne s'applique, mais le temps et la mémoire d'encodage croissent avec le compte. Pour un compte de plusieurs millions, l'encodage deviendrait impraticable. **Mesuré jusqu'à 10 000 au § 5.**

**B7, hors du sujet de `DrawIndirectCount`.** Chaque dessin reste limité à `UINT32_MAX` enregistrements (sommets × instances × vues). Au-delà, le GPU le refuse et le device est perdu à la fin de la soumission. C'est le plafond d'identifiants, qui relève de la continuation, pas de ce point.

## 3. Conclusion

- **Aucun plafond privé n'est nécessaire sur l'instantané**, et `maxDrawIndirectCount` peut rester à `UINT32_MAX` : tout compte légal tient dans les buffers Metal (B1 à B4).
- Le coût mémoire (B5) est borné par l'étendue du buffer d'arguments, et son échec est un code d'erreur légal.
- **Le point ouvert réel est B6**, l'encodage du rejeu proportionnel au compte réel.

## 4. Traitement proposé et oracles, avant tout code

1. **Verrouiller B1, B3 et B4 par une vérification CPU.**
   - Les tailles du plan et de l'instantané passent dans deux fonctions sans état de `MVKPerVertexScratch.h`, sans changement de comportement.
   - Un test hôte vérifie, pour les deux tailles de commande, des strides de `sizeof(commande)` à 4 × `sizeof`, des offsets alignés et 1 à 32 passes multiview, que l'instantané ne dépasse jamais l'étendue légale du buffer d'arguments, jusqu'au pire cas M4 et au-delà.
   - Il vérifie aussi que `mvkSizePerVertexIndirectReplay()` refuse un compte figé plus grand que l'instantané.
   - Oracle : rouge si l'une des fonctions calcule une taille qui dépasse l'étendue légale ; vert sinon.
2. **Écrire la limite de B6 et la mesurer.**
   - Un essai GPU court sur M4, sous validation Metal : `vkCmdDrawIndirectCount` avec un `maxDrawCount` grand (1 million, buffer de 16 Mo) et un compte réel petit. Oracle : pixels corrects, instantané de 16 Mo alloué, rendu inchangé.
   - Puis un compte réel croissant (1, 100, 10 000), en mesurant le temps d'encodage du rejeu et le nombre d'encodeurs.
   - Oracle : rendu correct à chaque taille ; courbe mesurée et publiée, sans seuil caché.
3. **Proposer ensuite, séparément, un rejeu groupé.** Tables et préfixes par dessin seraient alloués après le plan, à partir du compte figé, et une seule capture et un seul rejeu serviraient à tous les dessins. L'encodage ne dépendrait plus du compte. C'est une conception à part, avec son propre oracle (nombre d'encodeurs indépendant du compte), à soumettre avant tout code.

Le plan partagé (`PLAN-PERVERTEX-UPSTREAM.md`, ligne 145) décrit encore l'ancienne formule. Je ne le modifie pas ; ce document en donne l'état actuel.

## 5. Mesure de B6 sur M4 Pro (29 septembre 2026)

Accord d'Astra : l'étape 2 seule, courte et bornée. La vérification CPU de l'étape 1 est refusée. Aucun rejeu groupé n'est conçu avant cette mesure.

### Montage

- Programme `PerVertexIndirectScaleTests.mm` et script `run-pervertex-indirect-scale-tests.sh`, commit `2e26ae7a`. Bibliothèque `lib-a3f02d1c` (sha256 `4e1b069a…`), Apple M4 Pro, macOS 27.2.
- Preuves : `build/astra/b6-scale-a3f02d1c/`, avec `INPUTS.sha256`, `results.csv` et un journal par palier.
- **L'essai.** Un seul `vkCmdDrawIndirectCount` non indexé, avec un stride de 16. Le buffer d'arguments fait `maxDrawCount × 16` octets, soit 16 Mo pour 1 million. Les `count` premières commandes sont le dessin de base du harnais indirect (6 sommets, 2 instances, 12 invocations). Les suivantes sont à zéro.
- **La référence.** Les mêmes `count` dessins, enregistrés en dessins directs. Le fragment lit aussi `BaryCoordKHR`, donc les deux chemins prennent la capture et le rejeu portables sur tout GPU.
- Chaque command buffer est soumis deux fois : à froid, puis à chaud.
- Tout tourne sous `MTL_DEBUG_LAYER=1` et `MTL_SHADER_VALIDATION=1`, un palier à la fois, avec un délai de 120 s.
- Les paliers : 1, puis 100, puis 10 000 dessins réels sous `maxDrawCount = 1 000 000`. Un témoin passe 100 dessins sous `maxDrawCount = 100`. Le palier de 10 000 n'a été lancé qu'après celui de 100 : une projection linéaire donnait environ 1,4 s d'encodage.

### Lecture des temps

- **`vkQueueSubmit` ne mesure pas l'encodage indirect.** Une soumission qui contient une continuation passe par un worker (`needsWorker()`, `MVKQueue.h:287`). L'appel rend donc la main en moins d'1 ms.
- Le programme horodate chaque création d'encodeur et chaque commit Metal, par un swizzle sur la classe de command buffer la plus externe (`MTLDebugCommandBuffer`). Ces dates ne dépendent pas du fil qui encode.
- **Le temps d'encodage** va du début de la soumission au dernier commit Metal. Pour l'indirect, il se découpe en trois parties :
  - l'avant-plan, jusqu'au commit de la phase 0 ;
  - l'attente du plan GPU, jusqu'à l'encodeur suivant ;
  - l'encodage du rejeu, jusqu'au dernier commit.
- **Le temps GPU est dérivé** : fin de l'attente de la fence, moins la date du dernier commit.

### Résultats

**Temps d'encodage**, en ms. Valeur à chaud, valeur à froid entre parenthèses.

| `maxDrawCount` : compte | Indirect, total | Dont attente du plan | Dont rejeu | Rejeu par dessin | Direct, total | Direct par dessin |
| --- | --- | --- | --- | --- | --- | --- |
| 1 000 000 : 1 | 2,5 (18,5) | 1,3 (11,9) | 0,29 (1,6) | 0,29 | 0,4 (0,4) | 0,36 |
| 1 000 000 : 100 | 16,3 (31,6) | 1,2 (12,5) | 13,7 (17,3) | 0,137 | 12,4 (11,7) | 0,124 |
| 100 : 100 (témoin) | 14,4 (26,0) | 0,8 (8,1) | 13,1 (16,3) | 0,131 | 11,7 (11,8) | 0,117 |
| 1 000 000 : 10 000 | 1 852 (2 393) | 204 (10,9) | 1 646 (2 380) | 0,165 | 13 250 (19 626) | 1,325 |

**Temps GPU dérivé**, en ms, à chaud (à froid).

| Compte | Indirect | Direct |
| --- | --- | --- |
| 1 | 0,6 (2,0) | 0,8 (1,4) |
| 100 | 8,6 (20,1) | 4,6 (4,4) |
| 100, témoin | 15,7 (11,3) | 6,7 (6,7) |
| 10 000 | 1 037 (907) | 15 614 (18 196) |

**Nombre d'encodeurs par soumission**, identique aux deux passages.

| Compte | Indirect : compute | Indirect : rendu | Indirect : commits | Direct : rendu | Direct : commits | Blit, les deux |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 2 | 3 | 2 | 2 | 1 | 4 |
| 100 | 101 | 201 | 2 | 101 | 1 | 4 |
| 10 000 | 10 001 | 20 001 | 2 | 10 001 | 1 | 4 |

- En indirect : 1 + N encodeurs compute (la phase 0, puis un par dessin figé) et 1 + 2N encodeurs de rendu (capture puis rejeu de chaque dessin, boucle de `MVKCmdDraw.mm:1191`).
- En direct : 1 + N encodeurs de rendu.
- La pente est exacte à chaque palier.

**Pixels et invocations.**
- **0 pixel différent à chaque palier**, entre l'image indirecte et l'image directe.
- Cet oracle a un angle mort : le vertex shader décale chaque dessin de 0,25 × `drawId`, et à partir de `drawId` 7 le dessin sort de la cible. `covered_pixels` plafonne à 2 592 dès 100 dessins. L'égalité octet par octet ne couvre donc que les 7 premiers dessins.
- **L'enregistrement des invocations couvre tous les dessins** : 12/12, 1 200/1 200 et 120 000/120 000, en multiensembles identiques à l'attendu, pour les deux chemins et les deux passages.

**Validation Metal.**
- Les 4 journaux portent les deux marqueurs (API et GPU), aucune chaîne d'erreur, et sortent en 0.
- Tous les temps ci-dessus sont pris **sous validation**, donc gonflés.

**Instantané de 16 Mo alloué.**
- `currentAllocatedSize` croît de 23 609 344 octets à la première soumission indirecte avec `maxDrawCount = 1 000 000`. Il croît de 7 602 176 octets avec le témoin à 100.
- La différence, 16 007 168 octets, fait 977 pages de 16 Kio. Elle correspond à l'instantané de 16 000 000 octets, à une page près.
- Côté mémoire déjà allouée avant la soumission, le buffer d'arguments de 16 Mo explique l'écart de 976 pages entre les deux essais.

### Conclusion pour B6

- **L'encodage indirect est linéaire dans le compte réel.**
  - Il coûte environ 0,14 à 0,17 ms par dessin figé, sous validation, sur M4 Pro, avec 3 encodeurs par dessin.
  - Un `maxDrawCount` d'un million n'ajoute rien à l'encodage du rejeu (témoin : 13,1 contre 13,7 ms).
  - Il ajoute environ 0,4 ms à l'attente du plan à chaud, et 16 Mo de mémoire.
- **B6 n'est pas propre au chemin indirect.**
  - L'encodage proportionnel au compte est celui de tout dessin PerVertexKHR portable : un rejeu par dessin. Le chemin indirect y ajoute un encodeur compute et un encodeur de rendu par dessin.
  - À 100 dessins, les deux chemins coûtent à peu près pareil.
  - À 10 000, l'indirect est environ 7 fois plus rapide à encoder (1,85 s contre 13,25 s), parce que le direct se dégrade.
- Conformément à la demande, aucun seuil n'est posé et aucun rejeu groupé n'est conçu.

### Hors du périmètre de B6 : à décider

1. **Le direct n'est pas linéaire.**
   - Par dessin, l'encodage est multiplié par 11 (de 0,12 à 1,33 ms). Le temps GPU est multiplié par 2 300 à 3 400 pour 100 fois plus de dessins.
   - Hypothèse non vérifiée : chaque dessin direct prend sa propre réservation de scratch et la rend résidente (`nextPerVertexScratch()`, `MVKCommandBuffer.mm:815-841`). L'ensemble résident croît alors avec le nombre de dessins du command buffer. Le chemin indirect réutilise une seule réservation pour tous ses dessins figés.
   - Sous validation, un coût par encodeur proportionnel à l'ensemble résident donnerait cette forme quadratique. Ce n'est pas mesuré hors validation.
2. **L'attente du plan indirect** vaut 204 ms au passage à chaud de 10 000 dessins, contre 10,9 ms à froid. Ce n'est pas expliqué.
3. **La mémoire du direct à 10 000.** `currentAllocatedSize` croît encore de 1,8 Mo puis de 2,1 Mo à chaque nouvelle soumission du même command buffer. Rien de tel à 100.
4. **La mémoire de l'indirect à 10 000.** La première soumission ajoute 63 Mo, contre 23,6 Mo à 100. Ce n'est pas analysé.

### Non mesuré

- La forme indexée.
- L'exécution sans validation Metal.
- Les autres GPU : M1, M3 et Intel, à la fin, comme convenu.
- Les comptes au-delà de 10 000. Le buffer d'invocations du programme limite le compte à 21 845.

**Proposition, à décider.** Une seule exécution bornée sans validation, à 100 puis 10 000 dessins, séparerait le coût de la couche de validation du coût propre à MoltenVK. C'est surtout utile pour le chemin direct.
