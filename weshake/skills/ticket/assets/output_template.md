## Title: [Theme] Brief ticket description (max 15 words)

### Product description

<Clear, non-technical explanation of the feature from a product/user perspective: who uses it, what problem it solves, what the expected user experience is, and the business value. Avoid implementation details, file paths, or code references. A non-technical PM or designer should understand it.>

### Technical description

<Clear explanation of what needs to be done and why, from a developer perspective: scope of the work, technical approach, constraints, dependencies and impacts.>

### Endpoints

> This section only appears if endpoints need to be created or modified.

For each endpoint:

- **Method & Route**: `POST /api/v1/example`
- **Input**:
  ```json
  {
    "field": "type — description"
  }
  ```
- **Output**:
  ```json
  {
    "field": "type — description"
  }
  ```

### Files to Modify

| File              | Reason                                            |
| ----------------- | ------------------------------------------------- |
| `path/to/file.js` | Explanation of why this file needs to be modified |

## How to test

> Section rédigée à partir du rapport de l'agent `front-browsing-file` (appel obligatoire avant d'écrire cette section).

Deux cas possibles, selon la réponse OUI/NON de l'agent sur la faisabilité depuis l'interface :

- **OUI — test depuis l'interface** (privilégier ce cas quand l'agent le confirme) :
  - URL d'accès (`/chemin/de/la/page`)
  - Rôle / utilisateur requis
  - Données pré-requises
  - Étapes cliquables (1. …, 2. …)
  - Résultat attendu visible à l'écran
- **NON — test backend uniquement** (quand l'agent indique que le parcours n'existe pas côté front) :
  - Raison courte (ex: endpoint pas encore branché côté front, action admin non exposée, déclencheur cron/webhook)
  - Requête Postman : méthode + URL complète + body JSON + headers d'auth
  - Réponse attendue
