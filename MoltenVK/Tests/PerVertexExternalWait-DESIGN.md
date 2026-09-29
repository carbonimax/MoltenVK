# Attente Metal externe : conception révisée du retrait différé

Ce document est soumis à la revue Astra **avant toute implémentation**. Il révise la proposition de la troisième revue (rapport `PerVertexContinuation-REPORT.md`, section « Point 3 : attente Metal externe — blocage maintenu, refonte proposée »).

Rien de ce qui est décrit ici n'est codé. Les références de lignes portent sur le runtime de `7758838b`, identique à celui de `c78c0289`.

**Révision 3.** La revue Astra indépendante de la révision 2 (`6dee5d90`) a conclu NO-GO pour l'implémenter telle qu'écrite. Cette révision répond à chacun de ses constats (§0). La publication anticipée de la perte (R6) n'est pas codée et ne le sera pas avant une nouvelle revue. Les reproducteurs des constats vérifiables aujourd'hui sont écrits (§5.1).

## 0. Réponse au NO-GO du 29 septembre (revue de `6dee5d90`)

| Constat d'Astra | Vérifié dans le code | Correction | Section |
| --- | --- | --- | --- |
| Renommer les sept `destroy()` en `destroyNow()` sans changer leurs appels à la base crée une récursion | Oui : chaque corps appelle `Base::destroy()`, qui deviendrait le `destroy()` `final`, donc de nouveau `destroyNow()`. La phrase « leur corps ne change pas » de la révision 2 était **fausse** | Chaque appel à la base devient `Base::destroyNow()` ; garde de réentrée ; contrôle statique | R1, §3.1 |
| Le quota par `MVKQueue` ignore que plusieurs devices partagent une file Metal | Oui : `MVKQueueFamily::getMTLCommandQueue()` met les files en cache par device physique, pour tous les devices et d'un device au suivant ; `MVKQueue` ne la retient pas (`MVKQueue.mm:34-47`, `388`) | Compte par file Metal, dans la famille ; une file qui porte le travail bloqué d'un device perdu sort du cache ; `MVKQueue` retient sa file ; partage entre devices vivants : question ouverte | R2, §3.6 |
| Le retrait différé ne protège pas la mémoire hôte importée | Oui : `newBufferWithBytesNoCopy: … deallocator: nil` sur le pointeur de l'application (`MVKDeviceMemory.mm:259`) ; après `vkFreeMemory`, l'application peut libérer ses pages, ce que la spécification autorise dès qu'une attente a rendu `VK_ERROR_DEVICE_LOST` | Aucun report ne peut couvrir des pages que MoltenVK ne possède pas : publication anticipée **désactivée** pour un device qui avait de la mémoire hôte importée au début de la perte | R8, §3.7 |
| Ni tous les callbacks de présentation | Oui : `addPresentedHandler` (`MVKImage.mm:1745`) n'est compté nulle part ; il relâche l'image et signale des sémaphores et fences que l'application a pu détruire | Handlers de présentation comptés dans R5 ; hypothèse sur Metal écrite | R5, §3.9 |
| Les attentes de résultats de requêtes et de présentation survivent à la publication | Oui : `MVKQueryPool::getResults()` avec `VK_QUERY_RESULT_WAIT_BIT` (`MVKQueryPool.mm:86`) et `MVKSwapchain::waitForPresent()` (`MVKSwapchain.mm:248`) attendent sans condition de perte | Inventaire complet des attentes hôte ; chacune attend par tranches et sort sur perte publiée | R3, §3.8 |
| Durée de vie des listeners timeline | Oui : un listener sur un événement importé peut ne jamais rappeler ; il retient le sémaphore, dont le destructeur utilise le device. De plus, il identifie l'attente par l'adresse d'un objet de pile (**ABA**, trouvé à la relecture) | Le listener ne retient plus que un jeton détachable ; il n'est pas compté dans R5 | R9, §3.9 |
| Quarantaine des descriptor pools | Oui : `vkResetDescriptorPool` rembobine tout l'allocateur (`MVKDescriptorSet.mm:2231`) : une quarantaine par région n'y survit pas | Pendant une perte, le pool est épuisé jusqu'à sa destruction différée | R4, §3.10 |

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
| *Trouvé en plus* : le job de publication de la perte | `publishLoss()` s'exécute sur `_lossPublisher` après `markLost()`, puis commit un command buffer de secours (§3.2) | Un device supprimé dès que les compteurs sont à zéro pourrait l'être sous ce job |

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

Appels à la base dans ces corps : `MVKResource::destroy()` (buffer), `MVKVulkanAPIDeviceObject::destroy()` (vue de buffer, vue d'image, sampler, swapchain), `MVKImage::destroy()` (image de swapchain, `MVKImage` n'ayant pas de surcharge), `MVKSwapchainImage::destroy()` (image présentable). Tous résolvent vers `MVKVulkanAPIDeviceObject::destroy()` si celui-ci devient le point d'entrée `final` : un renommage seul boucle.

### 3.2 Acquisitions de command buffers Metal

Deux sites acquièrent un command buffer Metal :
- `MVKQueue::getMTLCommandBuffer()` (`MVKQueue.mm:220`), sur les files du device. Elles sont créées avec `maxActiveMetalCommandBuffersPerQueue` places (`MVKQueue.mm:43-44`). C'est le site qui peut bloquer.
- `MVKDevice::releaseSemaphoreWaitsAfterLoss()` (`MVKDevice.mm:4073`), sur la file de secours du device physique (`MVKDevice.mm:3821`, 64 places par défaut). Cette file ne porte jamais de travail de l'application, seulement les signaux qui libèrent les attentes Metal après une perte ; ses command buffers ne font que signaler des événements, donc elle ne sature pas. Elle n'a pas besoin de R2. Ses handlers sont comptés par `commitMTLCommandBuffer()`, donc elle entre dans R5.

Les appelants de `MVKQueue::getMTLCommandBuffer()` :
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

### 3.6 Files Metal partagées

- `MVKQueueFamily::getMTLCommandQueue()` (`MVKQueue.mm:34-47`) garde une `MTLCommandQueue` par index de file, dans la famille du **device physique**. Tous les `VkDevice` créés sur ce device physique, en même temps ou l'un après l'autre, reçoivent la même file pour le même index. Le cache évite la lenteur de création des files Metal (commentaire du code : des délais de 15 s).
- `MVKQueue` ne la retient pas (`MVKQueue.mm:388`).
- Le nombre de places est fixé une fois, à la création de la file.
- **Reproduit** (`shared-queue-block`, §5.1) : les deux devices exportent la même `MTLCommandQueue`. Un device sain qui la partage avec un device perdu est bloqué de deux façons :
  - quand la file est pleine, dans l'acquisition d'un command buffer Metal ;
  - même avec des places libres (témoin à 64 places), dans l'**ordre d'exécution** de la file : son travail passe derrière celui de l'autre device.
- Le second blocage ne dépend ni de la perte ni des places : deux devices vivants qui partagent une file Metal se ralentissent ou se bloquent l'un l'autre. Aucun compte de places ne le résout.

### 3.7 Mémoire hôte importée

- `VK_EXT_external_memory_host` : `MVKDeviceMemory` garde le pointeur de l'application (`MVKDeviceMemory.mm:330-335`), et crée son `MTLBuffer` par `newBufferWithBytesNoCopy:… deallocator: nil` (`MVKDeviceMemory.mm:259`). Il ne libère pas ces pages (`MVKDeviceMemory.mm:296`).
- La spécification (section *Lost Device*) dit que, pour décider si une ressource est encore utilisée par le device, un retour `VK_ERROR_DEVICE_LOST` équivaut à `VK_SUCCESS`. Après le rapport de la perte, l'application peut donc appeler `vkFreeMemory`, puis libérer ses pages.
- Un travail encore en vol qui écrit dans ce buffer écrirait alors dans une mémoire que l'application a rendue. Retenir le `MTLBuffer` n'y change rien.

### 3.8 Attentes hôte

La spécification (section *Lost Device*) exige que `vkDeviceWaitIdle`, `vkQueueWaitIdle`, `vkWaitForFences`, `vkAcquireNextImageKHR` avec un délai maximal, et `vkGetQueryPoolResults` avec `VK_QUERY_RESULT_WAIT_BIT` rendent la main en temps fini après une perte, avec `VK_SUCCESS` ou `VK_ERROR_DEVICE_LOST`.

| Attente | Code | Sort sur perte publiée aujourd'hui ? |
| --- | --- | --- |
| `vkWaitForFences`, `vkWaitSemaphores`, attente d'événement | `MVKFenceSitter`, `MVKSemaphoreImpl` inscrits au device (`_awaitingSemaphores`), `getHostWaitResult()` | oui, dès la publication |
| `vkQueueWaitIdle`, `vkDeviceWaitIdle` | `MVKQueue::waitIdle()` : variable de condition `_execQueueConditionVariable` (`MVKQueue.mm:201`), puis `waitUntilCompleted` (`MVKQueue.mm:206`) | **non** : bloque derrière le travail bloqué |
| `vkGetQueryPoolResults` + `WAIT_BIT` | `_availabilityBlocker.wait` (`MVKQueryPool.mm:86`), sans condition de perte | **non** |
| `vkWaitForPresentKHR`, `vkWaitForPresent2KHR` | `_currentPresentIdCondVar.wait_for` (`MVKSwapchain.mm:248`), sans condition de perte | **non** (hors de la liste de la spécification, mais `VK_ERROR_DEVICE_LOST` est un de ses retours) |
| `vkAcquireNextImageKHR` | ne bloque pas côté hôte : signale la fence ou le sémaphore quand l'image se libère (`MVKSwapchain.mm:77-103`) | l'attente suivante de la fence est couverte par la première ligne |
| `vkInvalidateMappedMemoryRanges`, `vkCopyImageToMemoryEXT` (macOS sans mémoire unifiée) | `waitUntilCompleted` (`MVKDevice.mm:5102`, `MVKImage.mm:823`) | **non** |
| attentes internes | encodage sur sémaphore émulé (`MVKSync.mm:227`, annulé par `markLost()`), continuation (`MVKQueue.mm:600`, par tranches), compilation (`MVKSync.mm:553`, bornée par la configuration) | oui, ou bornées |

**Reproduit** : `external-queue-wait-idle` et `external-queue-wait-query` (§5.1).

### 3.9 Callbacks hors command buffer

- **Handler de présentation** (`[CAMetalDrawable addPresentedHandler:]`, `MVKImage.mm:1745`). Il est ajouté depuis le handler « scheduled » d'une présentation, qui est compté. Lui-même ne l'est pas. Il appelle `endPresentation()`, qui relâche l'image et signale les sémaphores et fences en attente d'acquisition. Si l'application les a détruits après la perte (R1 les diffère), et que le device est retiré avant ce handler, ce dernier touche des objets supprimés.
- **Listener `MTLSharedEvent`** des attentes timeline (`MVKTimelineSemaphoreMTLEvent::registerWait()`, `MVKSync.mm:289-306`).
  - Il retient le sémaphore et le relâche à la fin du bloc. Le destructeur du sémaphore utilise le device quand ses attentes Metal ont été libérées après une perte (`_isLossReleased`, `MVKSync.mm:331-333`).
  - Sur un événement importé, la valeur attendue peut ne jamais être atteinte : le listener ne rappelle jamais.
  - Il identifie l'attente par l'adresse du `MVKFenceSitter`, un objet de pile de `vkWaitSemaphores()` (`MVKSync.mm:515`). `unregisterWait()` le retire de `_sitters` au retour, mais le listener reste inscrit chez Metal. Une attente suivante, au même endroit de la pile, a la même adresse : l'ancien listener la réveille. `vkWaitSemaphores()` rend alors `VK_SUCCESS` sans relire la valeur (`MVKSync.mm:525-526`). **Défaut actuel, sans perte**, à reproduire (`timeline-listener-aba`, §5.1).
- **Handlers de compilation** (`MVKShaderModule.mm:586`, `725`, `MVKPipeline.mm:3613`, `3648`) : ils ne touchent que leur `MVKMetalCompiler`, dont la destruction attend déjà la fin de la compilation (`MVKSync.mm:582`). Inchangés.

### 3.10 Réinitialisation des descriptor pools

`MVKDescriptorPool::reset()` (`MVKDescriptorSet.mm:2231`) vide les listes libres et remet à zéro les allocateurs à bosse (`_cpuBufferUsed`, `_gpuBufferUsed`, `_numAllocatedDescriptorSets`). `freeDescriptorSets()` (`MVKDescriptorSet.mm:2203`) rend les régions aux listes libres. Une quarantaine qui ne toucherait qu'aux listes libres ne survivrait pas à un reset.

## 4. Conception révisée

### R1. Destruction différée, avant toute libération

1. `MVKVulkanAPIDeviceObject::destroy()` devient `final` :
   - si le device est en perte (`isLosing()`) **et n'est pas en cours de retrait**, l'objet est ajouté à une liste FIFO du device, et `destroy()` rend la main sans rien libérer ;
   - sinon, il appelle `destroyNow()`. C'est aussi le cas quand l'objet n'a plus de device : `MVKSwapchainImage::detachSwapchain()` met `_device` à nul (`MVKImage.mm:1545`).
2. `virtual void destroyNow()` fait par défaut `MVKVulkanAPIObject::destroy()`, c'est-à-dire la libération de la référence.
   - Les 7 surcharges du §3.1 deviennent des surcharges de `destroyNow()`.
   - **Leur appel à la base change aussi** : `MVKResource::destroy()`, `MVKVulkanAPIDeviceObject::destroy()`, `MVKImage::destroy()` et `MVKSwapchainImage::destroy()` deviennent `MVKResource::destroyNow()`, `MVKVulkanAPIDeviceObject::destroyNow()`, `MVKImage::destroyNow()` et `MVKSwapchainImage::destroyNow()`. Un appel resté à `destroy()` rentrerait dans le `destroy()` `final`, puis de nouveau dans `destroyNow()` : récursion sans fin.
   - `final` fait refuser par le compilateur toute nouvelle surcharge de `destroy()` : une sous-classe future ne peut plus contourner le report.
   - **Garde de réentrée.** Le `destroy()` `final` marque l'objet ; un second appel sur un objet déjà marqué est une erreur de programmation : assertion en Debug, retour sans effet en Release.
   - **Contrôle statique** (CPU, dans l'esprit de `run-pervertex-handler-tracking-tests.sh`) : aucun corps de `destroyNow()` n'appelle `::destroy()` ; aucune classe dérivée de `MVKVulkanAPIDeviceObject` ne déclare `destroy()`.
3. Le retrait du device (R5) vide la liste **dans l'ordre FIFO**, avant de démonter quoi que ce soit : il appelle `destroyNow()` sur chaque objet. L'ordre de destruction de l'application est ainsi rejoué (un buffer avant sa mémoire, par exemple).
   - Il vide la liste **jusqu'à ce qu'elle soit vide**, sans en prendre d'instantané.
   - Pendant le retrait, `destroy()` ne diffère plus rien (point 1). Les objets que détruisent les `destroyNow()` vidés, ou `~MVKDevice` lui-même, sont donc détruits aussitôt : les images de transfert de `MVKCommandEncodingPool::destroyMetalResources()`, les images présentables d'un swapchain différé.
4. Les destructions internes au device, avant son retrait, passent aussi par `destroy()` : images de transfert du pool d'encodage, images présentables. Pendant une perte, elles sont donc reportées aussi.
5. **Le swapchain retient sa surface**, de sa création à son destructeur. Il en va de même pour tout objet différé qui garde un objet de l'instance.

Destruction en course avec le début de la perte : un objet détruit juste avant, alors que du travail en attente l'utilise, reste un usage invalide de l'application. Ce cas est inchangé.

### R2. Places Metal comptées par MoltenVK, par file Metal

0. **Le compte appartient à la file Metal, pas à `MVKQueue`.** Il vit dans l'entrée du cache de `MVKQueueFamily`, à côté de la `MTLCommandQueue`, et tous les devices qui reçoivent cette file le partagent. `MVKQueue` retient sa file et une référence à cette entrée.
   - **File contaminée.** Quand la perte d'un device commence alors que du travail de MoltenVK est en cours sur une file Metal, cette file sort du cache : le prochain device qui demande cet index reçoit une file neuve. Le device perdu garde l'ancienne jusqu'à son retrait. Coût : une création de file Metal après une perte seulement.
   - **Devices vivants en même temps.** Un device sain qui partage déjà la file d'un device perdu attend le travail bloqué de l'autre, par les places **et** par l'ordre d'exécution de la file (§3.6). Ce n'est pas nouveau : `shared-queue-block` (§5.1) le reproduit sur le runtime actuel. R2 ne règle que les places ; seule une file par device vivant réglerait l'ordre. C'est une **question pour la revue** (§7).
1. Chaque file Metal compte ses command buffers Metal en cours.
   - Une place est prise à l'acquisition.
   - Elle est rendue à la fin du dernier handler d'un command buffer commité, ou à l'abandon d'un command buffer jamais mis en file.
   - La place d'un command buffer commité est rendue par le handler de la file, enregistré à l'acquisition (`MVKQueue.mm:226`). Ce handler s'exécute dans la liste du device, donc **avant** le décrément de `_pendingMTLCommandBufferHandlers`. L'entrée du cache, retenue par ce handler, survit de toute façon au device.
2. La `MTLCommandQueue` est créée avec **deux fois** `maxActiveMetalCommandBuffersPerQueue` places. MoltenVK n'en prend que `maxActiveMetalCommandBuffersPerQueue`.
   - La marge couvre le délai entre la place rendue par MoltenVK et celle rendue par Metal, ainsi que les références autorelease en retard.
   - Elle couvre aussi jusqu'à `maxActiveMetalCommandBuffersPerQueue` command buffers de l'application sur la file exportée.
   - Le nombre de places étant fixé à la création de la file, tous les devices d'un processus doivent lire la même configuration ; c'est déjà le cas aujourd'hui.
3. Quand toutes les places de MoltenVK sont prises, l'acquisition attend par tranches de 1 ms. Si `isLosing()`, elle rend `nil` **sans appeler Metal**.
4. Les appelants traitent `nil` :
   - la soumission, déjà : chemin nil, perte ;
   - le préremplissage : le command buffer s'enregistre sans préremplissage. Il faut une garde pour l'encodeur immédiat, qui ne doit pas commencer sur `nil` ;
   - `waitIdle()` : rien à attendre (R3) ;
   - l'acquisition d'image et la présentation : déjà refusées pendant une perte par `MVKQueue::submit`.
5. Coût : un décrément atomique à l'acquisition, un incrément à la libération.

**Écarté : « garer » l'encodage** pendant l'appel à Metal, en le retirant de `_activeEncodings`. Au réveil, le fil reprendrait l'encodage de command buffers que l'application peut avoir libérés après le rapport de la perte.

### R3. Toutes les attentes hôte sortent sur perte publiée

Règle unique pour chaque attente de l'inventaire §3.8 qui ne sort pas aujourd'hui : elle attend **par tranches de 1 ms**, et sort quand la perte est publiée. Elle rend alors `VK_ERROR_DEVICE_LOST`. Les attentes déjà inscrites au device (fences, sémaphores, événements) ne changent pas.

- `MVKQueue::waitIdle()` : l'attente de `_execQueueJobCount` et celle du command buffer vide passent par tranches ; le command buffer vide signale un sémaphore depuis son handler, que le bloc retient, comme dans `continueOnNewMTLCommandBuffer()`. Pendant une perte, aucune acquisition (R2).
- `MVKQueryPool::getResults()` avec `VK_QUERY_RESULT_WAIT_BIT` : `wait_for` par tranches, avec la perte publiée dans le prédicat.
- `MVKSwapchain::waitForPresent()` : idem, dans la limite du délai de l'application.
- `invalidateMappedMemoryRanges()` et `copyImageToMemory()` : comme `waitIdle()`.

Une tranche de 1 ms ne coûte que quand l'attente dure ; le chemin sans attente est inchangé.

### R4. Pools pendant la perte

| Pool | Pendant la perte |
| --- | --- |
| Descriptor sets (`vkFreeDescriptorSets`, `vkResetDescriptorPool`) | **Pool épuisé** (§3.10) : pendant une perte, `freeDescriptorSets()` ne rend rien aux listes libres, et `reset()` ne rembobine pas les allocateurs ; il marque le pool épuisé. Toute allocation suivante dans ce pool rend `VK_ERROR_OUT_OF_POOL_MEMORY`, ce que Vulkan permet. Tout est rendu à la destruction du pool, elle-même différée (R1). Le retour arrière interne d'une allocation qui échoue (`MVKDescriptorSet.mm:2217-2225`) ne touche que des régions que rien n'a encore utilisées : inchangé. |
| Command buffers et commandes (`vkResetCommandPool`, `vkResetCommandBuffer`, `vkFreeCommandBuffers`, reset implicite de `vkBeginCommandBuffer`) | Recyclage **conservé** : aucun handler ne les capture (§3.4). L'oracle O6 le prouve. |
| Allocations temporaires (`MVKMTLBufferAllocationPool`) | Inchangé : rendues exactement une fois, par leur handler (`7758838b`). Leur pool vit tant que le pool de commandes, dont la destruction est différée. |
| Requêtes (`vkResetQueryPool`) | Inchangé. Un `finishQueries` en retard peut encore marquer des requêtes disponibles. Après une perte, les résultats sont indéfinis selon Vulkan ; la mémoire reste valide, puisque la destruction du pool est différée. |
| Visibility buffers du device | Rendus au commit, comme en amont. **Non analysé** pour la perte : question ouverte. |

### R5. Vie du device, et suppression hors des callbacks

1. Le device se supprime quand cinq conditions sont réunies (les listeners `MTLSharedEvent` n'en font plus partie : R9) :
   - l'application a appelé `vkDestroyDevice` ;
   - aucun encodage n'est en cours (`_activeEncodings`) ;
   - aucun handler n'est en attente (`_pendingMTLCommandBufferHandlers`) ;
   - aucun handler de présentation (`addPresentedHandler`) n'est en attente (compteur nouveau, pris avant l'ajout, rendu comme dernier geste du handler). Hypothèse, à vérifier : Metal appelle ce handler quand le drawable est présenté **ou** abandonné. Si un drawable pouvait ne jamais le rappeler, le device fuirait, sans accès libéré ;
   - aucun job de publication de la perte n'est en file ou en cours sur `_lossPublisher` (compteur nouveau, pris dans `markLost()` avant le `dispatch_async`). Sans cette condition, les quatre autres peuvent être à zéro pendant que le job attend. Or `publishLoss()` commit ensuite le command buffer de secours (`MVKDevice.mm:4073`) : le device serait supprimé sous un job en cours, avant les handlers de ce command buffer.
2. `vkDestroyDevice` :
   - si les compteurs sont à zéro, supprime le device sur place, comme aujourd'hui : une application normale garde une destruction synchrone ;
   - sinon, rend la main.
3. Le dernier décrément qui ramène tout à zéro met la suppression en file sur une **file de dispatch série de MoltenVK**, commune au processus. La suppression ne s'exécute jamais dans un handler Metal, ni sur le fil de l'application.
4. Les deux chemins de retrait, sur place dans `vkDestroyDevice` comme sur la file de MoltenVK, font la même chose, dans cet ordre :
   - ils passent en état de retrait (R1, point 1) ;
   - ils vident la liste de R1 ;
   - ils exécutent `~MVKDevice`, sans ses attentes, puisqu'elles sont tenues par construction. Son `dispatch_sync(_lossPublisher)` (`MVKDevice.mm:5855`) rend alors la main aussitôt.
5. Le device retient son instance. `vkDestroyInstance` après `vkDestroyDevice` diffère donc la suppression de l'instance jusqu'à celle du device, sur la même file.
6. Un handler ne touche plus le device après son décrément : le décrément est sa dernière instruction, comme aujourd'hui dans `commitMTLCommandBuffer()`.

### R6. Publication en temps fini

`publishLoss()` n'attend plus que `_activeEncodings`, borné grâce à R2. Il n'attend plus les handlers, **sauf dans le cas de R8**. Les attentes hôte de §3.8 rendent `VK_ERROR_DEVICE_LOST` en temps fini (R3).

La publication ordonnée de `c78c0289` est inchangée. Une soumission bloquée retient les soumissions suivantes de sa file jusqu'à sa fin, ou jusqu'au retrait du device. Leurs fences et sémaphores ne sont pas signalés, ce qui est correct pendant une perte.

### R8. Mémoire hôte importée : pas de publication anticipée

- `markLost()` relève le nombre d'allocations `VK_EXT_external_memory_host` vivantes (compteur nouveau, tenu par `MVKDeviceMemory`).
- S'il n'est pas nul, `publishLoss()` garde le comportement actuel : il attend les handlers, avec l'avertissement de `d869010d`. Le rapport vient après le retrait du travail, et l'application ne peut libérer ses pages qu'ensuite.
- Une allocation importée **après** le début de la perte ne compte pas : aucun travail encodé avant la perte ne l'utilise.
- **G1 n'est donc pas garanti pour une application qui importe de la mémoire hôte** et dont le travail attend une autre application. C'est une limite, à documenter : aucune conception fondée sur le report ne peut la lever, puisque MoltenVK ne possède pas ces pages.

### R9. Listeners timeline : un jeton détachable

- `registerWait()` crée, pour chaque inscription, un petit jeton compté : un verrou et un pointeur vers le `MVKFenceSitter`.
- Le bloc du listener ne capture que ce jeton. Il ne retient plus le sémaphore : sa fin ne peut plus déclencher une destruction qui touche le device.
- `unregisterWait()` détache le jeton, sous son verrou, avant le retour de l'attente. Le bloc ne signale que si le jeton est encore attaché.
- Effets :
  - l'ABA de §3.9 disparaît : l'identité est celle du jeton, plus l'adresse d'un objet de pile ;
  - un listener qui ne rappelle jamais ne retient qu'un jeton, pas le sémaphore ni le device : il n'entre pas dans R5.
- Cette pièce corrige aussi un défaut actuel, sans lien avec la perte. Elle peut être proposée seule, avec son reproducteur, si la revue le juge utile.

### R7. Hors garantie, à dire explicitement

- Détruire un objet, ou le device, **avant** le début d'une perte, alors que du travail en attente l'utilise : usage invalide, inchangé.
- Une application qui garde plus de `maxActiveMetalCommandBuffersPerQueue` command buffers en attente sur une file exportée : l'acquisition de MoltenVK peut encore bloquer dans Metal.
- Un travail que l'application ne libère jamais : le device, et les objets différés, restent alloués jusqu'à la fin du processus. `vkDestroyDevice` rend la main. La fuite se limite au device perdu : aucun accès à de la mémoire libérée.
- Mémoire hôte importée au début de la perte : pas de publication anticipée (R8).
- Un device sain qui partage, au moment de la perte d'un autre, la file Metal que bloque le travail de celui-ci (R2, point 0).
- Un handler de présentation que Metal ne rappellerait jamais : fuite du device (R5).

## 5. Oracles, à écrire avant l'implémentation

Chaque oracle doit échouer sur `7758838b` (ou avec la pièce correspondante retirée) et passer après. Sur `7758838b`, O2 à O6 échouent d'abord par **délai dépassé** : la perte n'est pas rapportée en 2 s, et l'étape suivante n'est jamais atteinte. Leurs témoins de fond sont donc ceux de O7, pièce par pièce, sur la bibliothèque corrigée. Par exemple, pour O2, la référence faible devient nulle aussitôt après `vkDestroyBuffer` si R1 intercepte au point central, après les surcharges. Tous tournent sous validation Metal de l'API et des shaders, avec des handlers retardés comme les oracles actuels.

| Oracle | Scénario | Réussite |
| --- | --- | --- |
| **O1** `external-queue-wait` | le reproducteur actuel | perte rapportée en moins de 2 s ; C s'exécute après le signal de l'application, sans erreur de validation |
| **O2** destruction après le rapport | après le rapport, et pendant que C est bloqué, détruire tout ce que C utilise : `VkBuffer` (surcharge `destroyNow`), vue de buffer, vue d'image, sampler, mémoire, pipeline, pool de commandes, descriptor pool. Libérer ensuite l'événement, puis détruire le device | aucune erreur de validation, aucun plantage. Le test **ne retient pas** le `MTLBuffer` exporté (`VK_EXT_metal_objects`) de la cible de C ; il n'en garde qu'une référence faible (`objc_storeWeak`). Celle-ci doit rester non nulle après les destructions, et montrer l'écriture de C après le signal. Elle doit être nulle après le retrait du device. Un crochet de test, `mvkTestGetDeferredDestroyCount`, compte les objets différés : c'est le repli si Metal refuse les références faibles |
| **O3** device et instance détruits pendant le blocage | `vkDestroyDevice` puis `vkDestroyInstance` juste après le rapport | les deux rendent la main en moins de 100 ms ; après le signal, le device est supprimé une seule fois, hors d'un fil Metal, puis l'instance (crochet de test) |
| **O4** file saturée | `maxActiveMetalCommandBuffersPerQueue=4` ; l'application garde 2 command buffers en attente sur la file exportée ; MoltenVK remplit les places restantes ; perte | rapport en temps fini ; `vkBeginCommandBuffer` avec préremplissage, appelé pendant la perte, rend la main |
| **O5** attentes idle | `vkQueueWaitIdle` et `vkDeviceWaitIdle` après la perte, pendant que C est bloqué | `VK_ERROR_DEVICE_LOST` en moins de 2 s |
| **O6** pools pendant la perte | après le rapport : reset, libération, réallocation et réenregistrement des command buffers et des descriptor sets de C ; puis signal | pas d'erreur de validation ; allocations temporaires rendues exactement une fois (`mvkTestGetOutstandingCommandPoolAllocations`) ; la quarantaine rend `VK_ERROR_OUT_OF_POOL_MEMORY` quand le pool est plein |
| **O9** attentes sans délai | `external-queue-wait-idle` et `external-queue-wait-query` (§5.1) ; `vkWaitForPresentKHR` si un chemin de présentation sans fenêtre est disponible | perte rapportée en moins de 2 s, puis C après le signal |
| **O10** files Metal | `shared-queue-block` (§5.1) ; puis un troisième device, créé après la perte du premier alors que son travail est bloqué | le troisième reçoit une autre file Metal, et sa soumission se termine ; `shared-queue-block` reste `BLOCKER` tant que la question du §7 n'est pas tranchée |
| **O11** mémoire hôte importée | C écrit dans un buffer lié à de la mémoire importée ; perte pendant le blocage | l'avertissement est émis, le rapport attend le retrait de C (R8), puis l'application peut libérer ses pages |
| **O12** listeners | `timeline-listener-aba` (§5.1) ; puis, après une perte, destruction du sémaphore et du device pendant qu'un listener sur un événement importé attend, et signal ensuite | aucun faux succès ; aucun plantage sous Guard Malloc |
| **O13** récursion de `destroyNow()` | contrôle statique de R1 ; O2 détruit un objet de chacune des 7 classes, dont un swapchain et ses images si un chemin sans fenêtre existe | contrôle vert ; aucune récursion, aucun plantage |
| **O7** témoins négatifs | chaque pièce retirée à tour de rôle (R1 sans `final`, avec interception au point central, ou avec un appel à la base resté à `destroy()` ; R2 sans marge, ou compté par `MVKQueue` ; R3 avec `waitUntilCompleted` ; R5 avec suppression inline ; R8 désactivé ; R9 avec l'adresse du sitter) | l'oracle correspondant échoue |
| **O8** non-régression et coût | oracles de perte, binaires, de continuation, suite M4, CTS de synchronisation ; `QueueRetirementBench` et `BinarySemaphoreBench` | tout vert ; coût mesuré avant/après, sur une charge identique |

### 5.1 Reproducteurs écrits dès maintenant

Ces modes de `PerVertexLossTests.mm` reproduisent, sur le runtime actuel, les constats vérifiables sans implémenter la conception. Résultats : section de la quatrième revue du rapport.

| Mode | Constat |
| --- | --- |
| `external-queue-wait-idle` | `vkQueueWaitIdle` ne rend pas la main derrière le travail bloqué |
| `external-queue-wait-query` | `vkGetQueryPoolResults` avec `VK_QUERY_RESULT_WAIT_BIT` non plus |
| `shared-queue-block` | deux devices reçoivent la même file Metal ; un device sain attend le travail d'un device perdu, par les places (file pleine) ou par l'ordre d'exécution (témoin à 64 places) |
| `timeline-listener-aba` | sans perte : un ancien listener réveille une attente plus récente, qui rend `VK_SUCCESS` sous sa valeur |

## 6. Ordre d'implémentation proposé, après la revue

0. R9 et O12 : défaut actuel, indépendant de la publication anticipée.
1. R1, avec la surface retenue, puis O2 et O13.
2. R3, puis O5.
3. R2, puis O4 et O10.
4. R5, puis O3.
5. R8, puis O11.
6. R6 : O1 et O9 passent de `BLOCKER` à `PASS`, seulement si O2 à O6 et O10 à O13 sont verts sur la même bibliothèque.
7. R4, puis O6.
8. O7 et O8.

## 7. Questions pour la revue

1. La marge de places (deux fois la configuration) est-elle acceptable, ou faut-il une option ?
2. Le report limité aux objets du device, la surface étant retenue par le swapchain, suffit-il ?
3. La fuite d'un device dont le travail n'est jamais libéré est-elle acceptable, faute de mieux ?
4. La quarantaine des descriptor pools peut rendre `VK_ERROR_OUT_OF_POOL_MEMORY` pendant une perte. Est-ce acceptable ?
5. Faut-il analyser les visibility buffers du device (R4) avant l'implémentation, ou pendant ?
6. **Files Metal partagées entre devices vivants** (R2, point 0) : faut-il que la famille cesse de donner une même file à deux devices vivants, au prix d'une création de file par device ? Le reproducteur montre que le partage lie aussi l'ordre d'exécution des deux devices, perte ou non. Ou bien un device sain peut-il rester bloqué tant que le travail d'un autre device, perdu, ne se termine pas ?
7. **Mémoire hôte importée** (R8) : le repli sur la publication actuelle est-il acceptable, G1 n'étant alors pas garanti pour ces applications ?
8. **Handlers de présentation** (R5) : l'hypothèse « appelé à la présentation ou à l'abandon » suffit-elle, ou faut-il un reproducteur avant l'implémentation ?
9. **R9** peut-il être proposé seul, avant la refonte, puisqu'il corrige un défaut actuel ?
