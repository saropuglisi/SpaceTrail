# SpaceTrail

<!-- impeccable:product-schema 1 -->

## Platform

macOS

## Stack

Swift, SwiftUI, SQLite, FSEvents e un broker gestito da macOS.

## Product Purpose

Capire dove finisce lo spazio sul Mac e individuare file da esaminare nel Finder.

## Operating Context

Il software chiede di scegliere l’accesso al disco prima di avviare la prima indicizzazione e aggiorna l'indice durante l'uso quotidiano. Quando serve, l'utente apre l'app e trova subito l'elenco dei file ordinabile. Una seconda vista permette di sfogliare le cartelle e vedere la dimensione di file e cartelle.

## Capabilities and Constraints

La panoramica mostra i file più pesanti, il peso delle cartelle e lo storico dell'archiviazione. Il broker usa aggiornamenti incrementali e verifiche periodiche a basso impatto.
