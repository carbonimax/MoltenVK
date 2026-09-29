# Attente Metal externe : conception révisée du retrait différé

Ce document est soumis à la revue Astra **avant toute implémentation**. Il révise la proposition de la troisième revue (rapport `PerVertexContinuation-REPORT.md`, section « Point 3 : attente Metal externe — blocage maintenu, refonte proposée »).

Rien de ce qui est décrit ici n'est codé. Les références de lignes portent sur le runtime de `7758838b`, identique à celui de `c78c0289`.

## 1. Le problème

Le reproducteur `external-queue-wait` (`PerVertexLossTests.mm`) reste `BLOCKER`. Voici son déroulé :
1. L'application commit, sur la `MTLCommandQueue` exportée de la file B, un command buffer X. Il attend un `MTLSharedEvent` que MoltenVK ne connaît pas.
2. Elle soumet C sur la file B, derrière X.
3. Le device est perdu.
4. MoltenVK ne rapporte la perte qu'après la fin des handlers de C. Or ceux-ci attendent X, donc le signal de l'application : l'attente hôte rend `VK_TIMEOUT`.

La conception doit tenir deux garanties à la fois :
- **G1.** Les attentes hôte rendent `VK_ERROR_DEVICE_LOST` en temps fini, même si l'application ne libère jamais son travail.
- **G2.** Rien de ce qu'utilise le travail commité encore en vol n'est libéré avant son retrait. Cela vaut pour le GPU (ressources Metal) comme pour les handlers CPU (objets MoltenVK).

Deux voies sont écartées, pour les raisons déjà données au rapport :
- publier la perte après un délai borné, sans rien retenir ;
- créer tous les command buffers à références retenues.

## 2. Ce que la proposition précédente manquait

| Point demandé | Constat dans le code | Conséquence pour la proposition précédente |
| --- | --- | --- |
| `destroy()` qui libère avant sa classe de base | 7 surcharges libèrent des objets Metal **avant** d'appeler la classe de base (§3.1) | I1 prévoyait d'intercepter dans `MVKVulkanAPIDeviceObject::destroy()`. Ce point n'est atteint qu'**après** ces libérations. **Faux.** |
| Acquisition Metal bloquante sur une file saturée | `commandBufferWithDescriptor:` bloque quand toutes les places de la file sont prises (§3.2). Un encodage peut s'y bloquer pour toujours | I4 posait que les encodages en cours sont bornés. **Faux** : publier après eux peut ne jamais finir |
| Destruction du device depuis un callback | Le dernier handler supprimerait le device dans un callback Metal : il y relâcherait la `MTLCommandQueue` de ce même handler, le `MTLDevice`, et ferait un `dispatch_sync` (§3.5) | Risque cité, sans solution. Il en faut une |
| Réutilisation des pools pendant la perte | Command buffers, descriptor sets, requêtes, allocations temporaires (§3.4) | Signalée, non traitée |
| *Trouvé en plus* : attentes de complétion bloquantes | `vkQueueWaitIdle`, `vkDeviceWaitIdle`, `vkInvalidateMappedMemoryRanges` et `vkCopyImageToMemoryEXT` appellent `waitUntilCompleted` (§3.3) | G1 resterait faux pour ces appels, même avec une publication en temps fini |
| *Trouvé en plus* : la surface du swapchain | `MVKSwapchain::destroy()` écrit dans `_surface`, que le swapchain ne retient pas (§3.1) | Un swapchain différé toucherait une surface détruite entre-temps |

## 3. Faits relevés

### 3.1 Surcharges de `destroy()`

`MVKReferenceCountingMixin::release()` (`Utility/MVKBaseObject.h:164`) appelle `BaseClass::destroy()` de façon statique, c'est-à-dire `delete this`. Les surcharges suivantes libèrent donc des objets Metal avant la suppression différée :

| Surcharge | Ce qu'elle libère avant la classe de base |
| --- | --- |
| `MVKBuffer::destroy()` (`MVKBuffer.mm:232`) | `detachMemory()` : `MTLBuffer` dédié, ensemble des ressources vivantes, résidence, lien à la mémoire |
| `MVKBufferView::destroy()` (`MVKBuffer.mm:334`) | texture de la vue, ressources vivantes, résidence |
| `MVKImageView::destroy()` (`MVKImage.mm:2393`) | plans de la vue, avec leurs textures |
| `MVKSampler::destroy()` (`MVKImage.mm:2690`) | `MTLSamplerState` |
| `MVKSwapchainImage::destroy()` (`MVKImage.mm:1548`) | détache le swapchain |
| `MVKPresentableSwapchainImage::destroy()` (`MVKImage.mm:1836`) | drawable, texture headless |
| `MVKSwapchain::destroy()` (`MVKSwapchain.mm:648`) | retire le swapchain de sa surface, force la fin des présentations, détruit les images présentables |

`MVKMetalCompiler::destroy()` n'est pas un objet du device : il n'est pas concerné. `MVKSwapchain` garde un `MVKSurface*` (`MVKSwapchain.h:129`) sans le retenir.

### 3.2 Acquisitions de command buffers Metal

Un seul site appelle Metal : `MVKQueue::getMTLCommandBuffer()` (`MVKQueue.mm:220`). La file est créée avec `maxActiveMetalCommandBuffersPerQueue` places (`MVKQueue.mm:43-44`).

Ses appelants :
- pendant un encodage de soumission, compté dans `_activeEncodings` : `getActiveMTLCommandBuffer()` et `continueOnNewMTLCommandBuffer()` ;
- sur le fil de l'application : `vkBeginCommandBuffer` avec préremplissage (`MVKCommandBuffer.mm:188`). Le command buffer prérempli garde sa place jusqu'à sa fin, ou jusqu'à son abandon ;
- `waitIdle()` (`MVKQueue.mm:204`), l'acquisition d'image (`MVKImage.mm:1615`), la présentation (`MVKQueue.mm:910`) ;
- sur macOS sans mémoire unifiée : `vkInvalidateMappedMemoryRanges` (`MVKDeviceMemory.mm:110`) et `vkCopyImageToMemoryEXT` (`MVKImage.mm:804`).

**Mesuré** (`build/astra/r3-slots`, `build/astra/r5-abandon-probe`, M4 et macOS 27.2) :
- sur une file de 4 places, la cinquième acquisition bloque tant que quatre command buffers gardent leur place ;
- un command buffer relâché sans `enqueue` ni `commit` rend sa place ;
- un command buffer mis en file (`enqueue`), puis relâché sans commit, garde sa place sans validation, et fait échouer une assertion de la validation de l'API (`enqueued-release-*.out`). MoltenVK ne le fait jamais.

Les command buffers bloqués derrière X gardent leur place. Les command buffers que l'application commit elle-même sur la file exportée en prennent aussi.

### 3.3 Attentes de complétion bloquantes

Les attentes suivantes n'ont pas de borne quand le travail ne se termine jamais :
- `MVKQueue::waitIdle()` : `waitUntilCompleted` (`MVKQueue.mm:206`). Elle sert `vkQueueWaitIdle` et `vkDeviceWaitIdle` ;
- `MVKDevice::invalidateMappedMemoryRanges()` (`MVKDevice.mm:5102`) ;
- `MVKImage::copyImageToMemory()` (`MVKImage.mm:823`).

Seul `continueOnNewMTLCommandBuffer()` attend par tranches de 1 ms, en surveillant `isLosing()`.

### 3.4 Handlers et objets qu'ils touchent

| Handler | Objets touchés |
| --- | --- |
| `MVKQueue::getMTLCommandBuffer` (`MVKQueue.mm:226`) | la file, le device (`handleMTLCommandBufferError`) |
| `commitActiveMTLCommandBuffer` (`MVKQueue.mm:681`) | la soumission (qui retient fence et sémaphores), la file, le device |
| `continueOnNewMTLCommandBuffer` (`MVKQueue.mm:596`) | un sémaphore de dispatch, retenu par le bloc |
| présentation (`MVKQueue.mm:937`, `MVKImage.mm:1677`, `1703`) | la soumission de présentation ; l'image, la fence et le drawable, retenus ; `_swapchain`, **non retenu** |
| `pullFromDeviceOnCompletion` (`MVKImage.mm:450`) | le plan d'image et la mémoire mappée |
| `keepPerVertexScratchResident` (`MVKCommandBuffer.mm:838`) | le device, le scratch (capturé par valeur) |
| `getTempMTLBuffer`, `vkCmdUpdateBuffer` (`MVKCommandBuffer.mm:1560`, `MVKCmdTransfer.mm:1795`) | l'allocation et son `MVKMTLBufferAllocationPool`, qui appartient au pool de commandes |
| `finishQueries` (`MVKCommandBuffer.mm:1710`) | les pools de requêtes |
| `MVKCmdTransfer.mm:544`, `590`, `706`, `MVKCommandBuffer.mm:1678` | des objets Metal retenus par le bloc |
| écouteurs `MTLSharedEvent` des attentes timeline (`MVKSync.mm:298`) | le sémaphore, retenu, dont le destructeur utilise le device |

Aucun handler ne capture un `MVKCommandBuffer`, un `MVKCommandEncoder` ou une `MVKCommand`.

**Pools :**
- `vkResetCommandPool` réinitialise ses command buffers et vide les pools de types de commandes (`MVKCommandPool.mm:34`, `85`). Il ne vide pas le pool d'encodage.
- Les allocations temporaires ne reviennent au pool d'encodage que par leur handler. L'oracle `7758838b` prouve qu'elles y reviennent exactement une fois.
- Les descriptor sets libérés rendent leur région d'argument buffer, qu'une allocation suivante réutilise.

### 3.5 Destruction du device

Deux points bloquent la destruction dans un callback :
- `~MVKDevice` (`MVKDevice.mm:5832`) attend `_activeEncodings` et `_pendingMTLCommandBufferHandlers`, puis détruit les files : leurs `MTLCommandQueue` sont relâchées ;
- `publishLoss()` (`MVKDevice.mm:4029`) attend `_pendingMTLCommandBufferHandlers` : c'est la cause directe du `BLOCKER`.

Si le dernier handler supprimait le device, cette suppression s'exécuterait dans un callback Metal de l'une de ces files. Apple ne documente pas qu'on puisse y relâcher la `MTLCommandQueue` ou le `MTLDevice` : Metal pourrait attendre son propre fil de complétion.

## 4. Conception révisée

### R1. Destruction différée, avant toute libération

1. `MVKVulkanAPIDeviceObject::destroy()` devient `final` :
   - si le device est en perte (`isLosing()`), l'objet est ajouté à une liste FIFO du device, et `destroy()` rend la main sans rien libérer ;
   - sinon, il appelle `destroyNow()`.
2. `virtual void destroyNow()` fait par défaut `MVKVulkanAPIObject::destroy()`.
   - Les 7 surcharges du §3.1 deviennent des surcharges de `destroyNow()` ; leur corps ne change pas.
   - `final` fait refuser par le compilateur toute nouvelle surcharge de `destroy()` : une sous-classe future ne peut plus contourner le report.
3. Le retrait du device (R5) vide la liste **dans l'ordre FIFO**, avant de démonter quoi que ce soit : il appelle `destroyNow()` sur chaque objet. L'ordre de destruction de l'application est ainsi rejoué (un buffer avant sa mémoire, par exemple).
4. Les destructions internes au device passent aussi par `destroy()` : images de transfert du pool d'encodage, images présentables. Elles sont donc reportées aussi.
5. **Le swapchain retient sa surface**, de sa création à son destructeur. Il en va de même pour tout objet différé qui garde un objet de l'instance.

Destruction en course avec le début de la perte : un objet détruit juste avant, alors que du travail en attente l'utilise, reste un usage invalide de l'application. Ce cas est inchangé.

### R2. Places Metal comptées par MoltenVK

1. Chaque `MVKQueue` compte ses command buffers Metal en cours.
   - Une place est prise à l'acquisition.
   - Elle est rendue à la fin du dernier handler d'un command buffer commité, ou à l'abandon d'un command buffer jamais mis en file.
2. La `MTLCommandQueue` est créée avec **deux fois** `maxActiveMetalCommandBuffersPerQueue` places. MoltenVK n'en prend que `maxActiveMetalCommandBuffersPerQueue`.
   - La marge couvre le délai entre la place rendue par MoltenVK et celle rendue par Metal, ainsi que les références autorelease en retard.
   - Elle couvre aussi jusqu'à `maxActiveMetalCommandBuffersPerQueue` command buffers de l'application sur la file exportée.
3. Quand toutes les places de MoltenVK sont prises, l'acquisition attend par tranches de 1 ms. Si `isLosing()`, elle rend `nil` **sans appeler Metal**.
4. Les appelants traitent `nil` :
   - la soumission, déjà : chemin nil, perte ;
   - le préremplissage : le command buffer s'enregistre sans préremplissage. Il faut une garde pour l'encodeur immédiat, qui ne doit pas commencer sur `nil` ;
   - `waitIdle()` : rien à attendre (R3) ;
   - l'acquisition d'image et la présentation : déjà refusées pendant une perte par `MVKQueue::submit`.
5. Coût : un décrément atomique à l'acquisition, un incrément à la libération.

**Écarté : « garer » l'encodage** pendant l'appel à Metal, en le retirant de `_activeEncodings`. Au réveil, le fil reprendrait l'encodage de command buffers que l'application peut avoir libérés après le rapport de la perte.

### R3. Attentes de complétion par tranches

`waitIdle()`, `invalidateMappedMemoryRanges()` et `copyImageToMemory()` n'appellent plus `waitUntilCompleted`. Ils attendent un sémaphore que signale le handler du command buffer, par tranches de 1 ms, et abandonnent l'attente si `isLosing()`. Ils rendent ensuite `getHostWaitResult()`. Le bloc garde sa propre référence au sémaphore, comme dans `continueOnNewMTLCommandBuffer()`.

### R4. Pools pendant la perte

| Pool | Pendant la perte |
| --- | --- |
| Descriptor sets (`vkFreeDescriptorSets`, `vkResetDescriptorPool`) | **Quarantaine** : les régions libérées ne reviennent pas à la liste libre. Une allocation qui n'a plus de place rend `VK_ERROR_OUT_OF_POOL_MEMORY`, ce que Vulkan permet. Tout est rendu à la destruction du pool, elle-même différée (R1). |
| Command buffers et commandes (`vkResetCommandPool`, `vkResetCommandBuffer`, `vkFreeCommandBuffers`, reset implicite de `vkBeginCommandBuffer`) | Recyclage **conservé** : aucun handler ne les capture (§3.4). L'oracle O6 le prouve. |
| Allocations temporaires (`MVKMTLBufferAllocationPool`) | Inchangé : rendues exactement une fois, par leur handler (`7758838b`). Leur pool vit tant que le pool de commandes, dont la destruction est différée. |
| Requêtes (`vkResetQueryPool`) | Inchangé. Un `finishQueries` en retard peut encore marquer des requêtes disponibles. Après une perte, les résultats sont indéfinis selon Vulkan ; la mémoire reste valide, puisque la destruction du pool est différée. |
| Visibility buffers du device | Rendus au commit, comme en amont. **Non analysé** pour la perte : question ouverte. |

### R5. Vie du device, et suppression hors des callbacks

1. Le device se supprime quand quatre conditions sont réunies :
   - l'application a appelé `vkDestroyDevice` ;
   - aucun encodage n'est en cours (`_activeEncodings`) ;
   - aucun handler n'est en attente (`_pendingMTLCommandBufferHandlers`) ;
   - aucun écouteur `MTLSharedEvent` n'est enregistré (compteur nouveau).
2. `vkDestroyDevice` :
   - si les compteurs sont à zéro, supprime le device sur place, comme aujourd'hui : une application normale garde une destruction synchrone ;
   - sinon, rend la main.
3. Le dernier décrément qui ramène tout à zéro met la suppression en file sur une **file de dispatch série de MoltenVK**, commune au processus. La suppression ne s'exécute jamais dans un handler Metal, ni sur le fil de l'application.
4. Le retrait vide d'abord la liste de R1. Il exécute ensuite `~MVKDevice`, sans ses attentes, puisqu'elles sont tenues par construction.
5. Le device retient son instance. `vkDestroyInstance` après `vkDestroyDevice` diffère donc la suppression de l'instance jusqu'à celle du device, sur la même file.
6. Un handler ne touche plus le device après son décrément : le décrément est sa dernière instruction, comme aujourd'hui dans `commitMTLCommandBuffer()`.

### R6. Publication en temps fini

`publishLoss()` n'attend plus que `_activeEncodings`, borné grâce à R2. Il n'attend plus les handlers. Les attentes hôte (fences, sémaphores, événements, et `waitIdle` par R3) rendent `VK_ERROR_DEVICE_LOST` en temps fini.

La publication ordonnée de `c78c0289` est inchangée. Une soumission bloquée retient les soumissions suivantes de sa file jusqu'à sa fin, ou jusqu'au retrait du device. Leurs fences et sémaphores ne sont pas signalés, ce qui est correct pendant une perte.

### R7. Hors garantie, à dire explicitement

- Détruire un objet, ou le device, **avant** le début d'une perte, alors que du travail en attente l'utilise : usage invalide, inchangé.
- Une application qui garde plus de `maxActiveMetalCommandBuffersPerQueue` command buffers en attente sur une file exportée : l'acquisition de MoltenVK peut encore bloquer dans Metal.
- Un travail que l'application ne libère jamais : le device, et les objets différés, restent alloués jusqu'à la fin du processus. `vkDestroyDevice` rend la main. La fuite se limite au device perdu : aucun accès à de la mémoire libérée.

## 5. Oracles, à écrire avant l'implémentation

Chaque oracle doit échouer sur `7758838b` (ou avec la pièce correspondante retirée) et passer après. Tous tournent sous validation Metal de l'API et des shaders, avec des handlers retardés comme les oracles actuels.

| Oracle | Scénario | Réussite |
| --- | --- | --- |
| **O1** `external-queue-wait` | le reproducteur actuel | perte rapportée en moins de 2 s ; C s'exécute après le signal de l'application, sans erreur de validation |
| **O2** destruction après le rapport | après le rapport, et pendant que C est bloqué, détruire tout ce que C utilise : `VkBuffer` (surcharge `destroyNow`), vue de buffer, vue d'image, sampler, mémoire, pipeline, pool de commandes, descriptor pool. Libérer ensuite l'événement | aucune erreur de validation, aucun plantage ; l'écriture de C arrive dans un `MTLBuffer` exporté (`VK_EXT_metal_objects`) et retenu par le test |
| **O3** device et instance détruits pendant le blocage | `vkDestroyDevice` puis `vkDestroyInstance` juste après le rapport | les deux rendent la main en moins de 100 ms ; après le signal, le device est supprimé une seule fois, hors d'un fil Metal, puis l'instance (crochet de test) |
| **O4** file saturée | `maxActiveMetalCommandBuffersPerQueue=4` ; l'application garde 2 command buffers en attente sur la file exportée ; MoltenVK remplit les places restantes ; perte | rapport en temps fini ; `vkBeginCommandBuffer` avec préremplissage, appelé pendant la perte, rend la main |
| **O5** attentes idle | `vkQueueWaitIdle` et `vkDeviceWaitIdle` après la perte, pendant que C est bloqué | `VK_ERROR_DEVICE_LOST` en moins de 2 s |
| **O6** pools pendant la perte | après le rapport : reset, libération, réallocation et réenregistrement des command buffers et des descriptor sets de C ; puis signal | pas d'erreur de validation ; allocations temporaires rendues exactement une fois (`mvkTestGetOutstandingCommandPoolAllocations`) ; la quarantaine rend `VK_ERROR_OUT_OF_POOL_MEMORY` quand le pool est plein |
| **O7** témoins négatifs | chaque pièce retirée à tour de rôle (R1 sans `final`, avec interception au point central ; R2 sans marge ; R3 avec `waitUntilCompleted` ; R5 avec suppression inline) | l'oracle correspondant échoue |
| **O8** non-régression et coût | oracles de perte, binaires, de continuation, suite M4, CTS de synchronisation ; `QueueRetirementBench` et `BinarySemaphoreBench` | tout vert ; coût mesuré avant/après, sur une charge identique |

## 6. Ordre d'implémentation proposé, après la revue

1. R1, avec la surface retenue, puis O2.
2. R3, puis O5.
3. R2, puis O4.
4. R5, puis O3.
5. R6 : O1 passe de `BLOCKER` à `PASS`, seulement si O2 à O6 sont verts sur la même bibliothèque.
6. R4, puis O6.
7. O7 et O8.

## 7. Questions pour la revue

1. La marge de places (deux fois la configuration) est-elle acceptable, ou faut-il une option ?
2. Le report limité aux objets du device, la surface étant retenue par le swapchain, suffit-il ?
3. La fuite d'un device dont le travail n'est jamais libéré est-elle acceptable, faute de mieux ?
4. La quarantaine des descriptor pools peut rendre `VK_ERROR_OUT_OF_POOL_MEMORY` pendant une perte. Est-ce acceptable ?
5. Faut-il analyser les visibility buffers du device (R4) avant l'implémentation, ou pendant ?
