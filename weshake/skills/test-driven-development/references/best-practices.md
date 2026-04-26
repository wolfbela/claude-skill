# Best Practices — Extracted from Code Reviews

These best practices are derived from recurring fix patterns observed across 40+ merged PRs. Each practice includes a description, a bad implementation example, and a good implementation example.

---

## 1. Always validate route parameters with Joi

Every route endpoint must have a Joi validation middleware. Missing validation allows malformed inputs (non-UUID IDs, injection strings) to reach the database layer.

**Bad implementation:**

```js
router.get("/:id/required-documents", controller.getRequiredDocuments);
```

**Good implementation:**

```js
const schema_getRequiredDocuments = {
  params: Joi.object({
    id: Joi.string().uuid().required(),
  }),
};

router.get(
  "/:id/required-documents",
  validate(schema_getRequiredDocuments),
  controller.getRequiredDocuments,
);
```

---

## 2. Add length limits on search and text inputs

String inputs — especially search fields — must have a `.max()` constraint to prevent oversized queries from hitting the database.

**Bad implementation:**

```js
text_search: Joi.string().optional(),
```

**Good implementation:**

```js
text_search: Joi.string().max(200).optional(),
```

---

## 3. Add batch size limits on array/list inputs

Endpoints that accept comma-separated IDs or arrays must enforce a maximum count to prevent abuse and excessive DB load.

**Bad implementation:**

```js
employee_ids: Joi.string().required(), // accepts unlimited IDs
```

**Good implementation:**

```js
employee_ids: Joi.string().required().custom((value, helpers) => {
  const ids = value.split(',');
  if (ids.length > 50) {
    return helpers.error('any.invalid');
  }
  return value;
}),
```

---

## 4. Write strict regex — require meaningful characters

Regular expressions for phone numbers, codes, or identifiers must require at least one meaningful character (e.g., a digit). Otherwise, strings made entirely of separators pass validation.

**Bad implementation:**

```js
const phoneRegex = /^[+]?[\d\s()-]{6,20}$/; // accepts "------"
```

**Good implementation:**

```js
const phoneRegex = /^(?=.*\d)[+]?[\d\s()-]{6,20}$/; // requires at least one digit
```

---

## 5. Distinguish create vs update nullability in validators

On creation endpoints, required fields should not accept `null`. On update endpoints, `.allow(null)` may be necessary to support field clearing. Do not blindly share the same schema for both.

**Bad implementation:**

```js
// Shared schema used for both create and update
const contactSchema = {
  phone: Joi.string().allow(null), // allows null even on creation
};
```

**Good implementation:**

```js
const createContactSchema = {
  phone: Joi.string().required(), // null not allowed on creation
};

const updateContactSchema = {
  phone: Joi.string().allow(null), // null allowed to clear the field
};
```

---

## 6. Check reference count before cascade-deleting shared resources

When deleting an entity that references a shared resource (user, address, etc.), always count how many other entities reference it before deleting. Perform the count inside the transaction.

**Bad implementation:**

```js
await destroy(EMPLOYEE, { id: employeeId }, { transaction });
// Unconditionally delete the linked user
if (employee.user_id && !employee.is_owner) {
  await destroy(USER, { id: employee.user_id }, { transaction });
}
```

**Good implementation:**

```js
await destroy(EMPLOYEE, { id: employeeId }, { transaction });
if (employee.user_id && !employee.is_owner) {
  const otherRefs = await count(
    EMPLOYEE,
    { user_id: employee.user_id },
    { transaction },
  );
  if (otherRefs === 0) {
    await destroy(USER, { id: employee.user_id }, { transaction });
  }
}
```

---

## 7. Scope bulk updates to the parent entity

When reordering or bulk-updating child records, always include the parent foreign key in the WHERE clause. Updating by primary key alone allows cross-entity mutation.

**Bad implementation:**

```js
// Only checks primary key — can update items from another parent
await updateOne(MODEL, id, { position: newPosition });
```

**Good implementation:**

```js
// Scoped to parent — prevents cross-entity mutation
await updateWhere(
  MODEL,
  { id, [parentFK]: parentId },
  { position: newPosition },
);
```

---

## 8. Handle unique indexes with soft-delete (paranoid) models

Unique indexes on paranoid models must account for soft-deleted rows. A soft-deleted row still occupies the unique slot unless the index is conditional. Use a generated column or a partial WHERE clause.

**Bad implementation:**

```js
// Soft-deleted row blocks re-creation
queryInterface.addIndex("product_suppliers", ["product_id", "supplier_id"], {
  unique: true,
});
```

**Good implementation:**

```sql
-- MySQL generated column: NULL for deleted rows (NULL is always unique)
ALTER TABLE product_suppliers
  ADD COLUMN active_flag TINYINT GENERATED ALWAYS AS (IF(deleted_at IS NULL, 1, NULL)) STORED;

CREATE UNIQUE INDEX idx_product_supplier_active
  ON product_suppliers (product_id, supplier_id, active_flag);
```

---

## 9. Clean up external resources (S3, cloud storage) on entity deletion

When an entity references an external resource (S3 object, cloud file), delete the external resource when the entity is destroyed. Wrap cleanup in `.catch()` so failures don't break the main operation.

**Bad implementation:**

```js
async deleteCategory(id) {
  await destroy(CATEGORY, { id });
  // S3 image is now orphaned
}
```

**Good implementation:**

```js
async deleteCategory(id) {
  const category = await findOne(CATEGORY, { id });
  await destroy(CATEGORY, { id });
  if (category.image_url) {
    const key = extractS3Key(category.image_url);
    if (key) {
      await s3Service.deleteObject(key).catch(err => console.error('S3 cleanup failed:', err));
    }
  }
}
```

---

## 10. Make expensive includes opt-in, not default

If a subquery or eager-loaded association is expensive (correlated subquery, heavy join), do not include it in the default includes. Make it opt-in via an options flag.

**Bad implementation:**

```js
function getDefaultUserIncludes() {
  return [
    { model: PROFILE },
    { model: ENDING_PROCESS, limit: 1, order: [["created_at", "DESC"]] }, // expensive, always loaded
  ];
}
```

**Good implementation:**

```js
function getDefaultUserIncludes({ includeEndingProcess = false } = {}) {
  const includes = [{ model: PROFILE }];
  if (includeEndingProcess) {
    includes.push({
      model: ENDING_PROCESS,
      limit: 1,
      order: [["created_at", "DESC"]],
    });
  }
  return includes;
}
```

---

## 11. Apply fixes to ALL parallel code paths

When fixing a bug in one code path (e.g., `getMe`), check all similar paths (e.g., `login`, `refresh`) for the same issue. A partial fix is an incomplete fix.

**Bad implementation:**

```js
// Fixed in getMe...
async getMe(req, res) {
  const user = await findOne(USER, { id: req.userId });
  user.permission = user.role?.permission || user.access_rights; // fixed
}

// ...but not in login
async login(req, res) {
  const user = await findOne(USER, { id });
  user.permission = user.role?.permission; // still broken for users without role
}
```

**Good implementation:**

```js
// Fix applied consistently in BOTH paths
function resolvePermission(user) {
  return user.role?.permission || user.access_rights;
}

async getMe(req, res) {
  const user = await findOne(USER, { id: req.userId });
  user.permission = resolvePermission(user);
}

async login(req, res) {
  const user = await findOne(USER, { id });
  user.permission = resolvePermission(user);
}
```

---

## 12. Do not restrict access before completing the operation that unlocks it

If an operation restricts user access (e.g., dashboard-only lockdown) and then performs an async step (e.g., start verification), failure in the async step leaves the user permanently locked out. Restrict access only AFTER the dependent operation succeeds.

**Bad implementation:**

```js
async startOnboarding(employee) {
  await updateAccessRights(employee.id, DASHBOARD_ONLY); // locked down
  const url = await getVerificationUrl(employee); // if this fails, user is stuck
  await sendNotification(employee, url);
}
```

**Good implementation:**

```js
async startOnboarding(employee) {
  const url = await getVerificationUrl(employee); // get URL first
  await updateAccessRights(employee.id, DASHBOARD_ONLY); // only lock down after success
  await sendNotification(employee, url);
}
```

---

## 13. Re-throw errors in webhook handlers instead of swallowing them

Webhook handlers that silently catch errors prevent retry mechanisms from working. If a webhook fails, let the error propagate so the provider retries the delivery.

**Bad implementation:**

```js
async handleWebhook(req, res) {
  try {
    await restoreAccess(req.body.userId);
    res.sendStatus(200);
  } catch (err) {
    console.error(err);
    res.sendStatus(200); // swallowed — no retry, user stays locked
  }
}
```

**Good implementation:**

```js
async handleWebhook(req, res) {
  try {
    await restoreAccess(req.body.userId);
    res.sendStatus(200);
  } catch (err) {
    console.error(err);
    throw err; // propagate so the webhook gets retried
  }
}
```

---

## 14. Use explicit match priority instead of relying on array order

When matching against a list of rules (exact match, prefix match, wildcard), use separate passes with explicit priority. Do not rely on `.find()` order.

**Bad implementation:**

```js
// Depends on array order — prefix might match before exact
const rule = rules.find((r) => code.startsWith(r.code));
```

**Good implementation:**

```js
// Explicit priority: exact match first, then prefix
const exactMatch = rules.find((r) => r.code === code);
if (exactMatch) return exactMatch;

const prefixMatch = rules.find((r) => code.startsWith(r.code));
return prefixMatch || null;
```

---

## 15. Extract duplicated logic into shared helpers

When the same block of logic appears 2+ times, extract it into a named helper function. This applies especially to data transformation, API call patterns, and object builders.

**Bad implementation:**

```js
// In method A
const doc = await downloadFromUrl(url);
const s3Key = await uploadToS3(doc, `docs/${id}`);
await createMetadata(id, s3Key, doc.type);

// In method B — exact same pattern copy-pasted
const doc = await downloadFromUrl(url);
const s3Key = await uploadToS3(doc, `docs/${id}`);
await createMetadata(id, s3Key, doc.type);
```

**Good implementation:**

```js
async _downloadAndStoreDocument(url, id) {
  const doc = await downloadFromUrl(url);
  const s3Key = await uploadToS3(doc, `docs/${id}`);
  await createMetadata(id, s3Key, doc.type);
  return s3Key;
}

// In method A
await this._downloadAndStoreDocument(url, id);

// In method B
await this._downloadAndStoreDocument(url, id);
```

---

## 16. Check for idempotency before creating alerts or notifications

Before creating an alert, notification, or any entity that could be triggered multiple times, check if an active one already exists with the same identifier to prevent duplicates.

**Bad implementation:**

```js
// Called on every webhook — creates duplicates
await create(ALERT, {
  type: "AML",
  stakeholder_identifier: stakeholder.id,
  status: "active",
});
```

**Good implementation:**

```js
const existing = await findOne(ALERT, {
  type: "AML",
  stakeholder_identifier: stakeholder.id,
  status: "active",
});
if (!existing) {
  await create(ALERT, {
    type: "AML",
    stakeholder_identifier: stakeholder.id,
    status: "active",
  });
}
```

---

## 17. Use Set instead of Array for static lookups

When checking membership against a static list of values (country codes, feature flags, allowed statuses), use a `Set` for O(1) lookups instead of `Array.includes()` which is O(n).

**Bad implementation:**

```js
const SUPPORTED_COUNTRIES = ['FR', 'DE', 'ES', 'IT', 'NL', 'BE', 'PT', 'AT', 'IE', 'FI'];

if (SUPPORTED_COUNTRIES.includes(countryCode)) { ... }
```

**Good implementation:**

```js
const SUPPORTED_COUNTRIES = new Set(['FR', 'DE', 'ES', 'IT', 'NL', 'BE', 'PT', 'AT', 'IE', 'FI']);

if (SUPPORTED_COUNTRIES.has(countryCode)) { ... }
```

---

## 18. Do not duplicate what the validation layer already handles

If Joi (or another validator) provides a `.default()` value, do not add a runtime fallback that does the same thing. It creates confusion about the source of truth.

**Bad implementation:**

```js
// Joi schema
status: (Joi.string().valid("open", "closed").default("open"),
  // Controller — redundant
  function makeData(body) {
    if (!body.status) body.status = "open"; // already handled by Joi
    return body;
  });
```

**Good implementation:**

```js
// Joi schema — single source of truth for defaults
status: (Joi.string().valid("open", "closed").default("open"),
  // Controller — trust the validator
  function makeData(body) {
    return body; // status is guaranteed to be set by Joi
  });
```

---

## 19. Remove dead configuration from models

Do not leave `paranoid`-related config (e.g., `deletedAt: 'deleted_at'`) on models where `paranoid: false`. It is misleading and suggests soft-delete support that does not exist.

**Bad implementation:**

```js
const Model = sequelize.define(
  "calendar",
  {
    // ...
  },
  {
    paranoid: false,
    deletedAt: "deleted_at", // dead config — paranoid is false
  },
);
```

**Good implementation:**

```js
const Model = sequelize.define(
  "calendar",
  {
    // ...
  },
  {
    paranoid: false,
    // no deletedAt — paranoid is disabled
  },
);
```

---

## 20. Guard afterUpdate hooks against all relevant triggers

Model hooks that trigger side effects (score recomputation, notifications) should not early-return based on a single field check. Other field changes may also require the side effect.

**Bad implementation:**

```js
Alert.afterUpdate(async (alert) => {
  const statusChanged = alert.changed("status");
  if (!statusChanged) return; // WRONG: score depends on severity too

  await computeUserRiskScoreSafe(alert.user_id);
  if (statusChanged) await recordHistory(alert);
});
```

**Good implementation:**

```js
Alert.afterUpdate(async (alert) => {
  // Always recompute score — severity, context, or status changes all affect it
  await computeUserRiskScoreSafe(alert.user_id);

  // Only record history on status transitions
  if (alert.changed("status")) {
    await recordHistory(alert);
  }
});
```

---

## 21. Format data consistently on both sides of a comparison

When comparing two values (e.g., checking if a phone number changed), apply the same formatting function to both sides. Never compare a raw value against a formatted one.

**Bad implementation:**

```js
function checkBlacklist(newPhone, currentUser) {
  // newPhone is already formatted by caller, but currentUser phone is raw
  if (String(newPhone) !== formatUserPhone(currentUser)) {
    await addToBlacklist(newPhone);
  }
}
```

**Good implementation:**

```js
function checkBlacklist(newPhone, currentUser) {
  const formattedNew = formatUserPhone({ phone: newPhone });
  const formattedCurrent = formatUserPhone(currentUser);
  if (formattedNew !== formattedCurrent) {
    await addToBlacklist(formattedNew);
  }
}
```

---

## 22. Use existing service methods instead of raw DB calls

When a service method exists for creating/updating an entity (with timestamps, hooks, validation), use it instead of raw `create()` or `update()` calls. This ensures consistent behavior.

**Bad implementation:**

```js
// Raw DB call — bypasses service logic, timestamps, hooks
await create(ALERT, {
  type: "AML_ENTERPRISE",
  user_id: userId,
  status: "active",
});
```

**Good implementation:**

```js
// Service method — handles timestamps, defaults, and hooks consistently
await OnboardingAlertService.createAlert({
  type: "AML_ENTERPRISE",
  user_id: userId,
  status: "active",
});
```

---

## 23. Add error logging before silent catches

When using `.catch()` to prevent failures from breaking the main flow (e.g., S3 cleanup, notification sends), always log the error. Silent failures are invisible in production.

**Bad implementation:**

```js
await s3.deleteObject(key).catch(() => {}); // failure is invisible
```

**Good implementation:**

```js
await s3
  .deleteObject(key)
  .catch((err) => console.error("S3 cleanup failed:", err));
```

---

## 24. Guard against redundant DB writes on combined operations

When an endpoint allows updating multiple fields at once, check that individual field handlers don't conflict with bulk handlers. If `members` array is provided alongside a boolean flag, avoid writing the flag separately.

**Bad implementation:**

```js
if (body.is_enabled !== undefined) {
  await update(CHANNEL, { id }, { is_enabled: body.is_enabled }); // writes to DB
}
if (body.members) {
  await syncMembers(id, body.members); // also writes is_enabled as part of sync
}
```

**Good implementation:**

```js
if (body.is_enabled !== undefined && !Array.isArray(body.members)) {
  await update(CHANNEL, { id }, { is_enabled: body.is_enabled });
}
if (body.members) {
  await syncMembers(id, body.members); // handles everything including is_enabled
}
```

---

## 25. Make migration operations idempotent

MySQL DDL auto-commits, so a partial migration failure leaves the DB in an intermediate state. Re-running the migration without guards will crash on already-applied operations. Wrap every `addIndex`, `removeIndex`, `addColumn`, `removeColumn` with existence checks.

**Bad implementation:**

```js
async up(queryInterface) {
  await queryInterface.addIndex('alerts', ['user_id', 'status'], { name: 'idx_alerts_user_status' });
  await queryInterface.addColumn('alerts', 'severity', { type: DataTypes.INTEGER });
}
```

**Good implementation:**

```js
async up(queryInterface) {
  const indexes = await queryInterface.showIndex('alerts');
  if (!indexes.find(i => i.name === 'idx_alerts_user_status')) {
    await queryInterface.addIndex('alerts', ['user_id', 'status'], { name: 'idx_alerts_user_status' });
  }

  const tableDesc = await queryInterface.describeTable('alerts');
  if (!tableDesc.severity) {
    await queryInterface.addColumn('alerts', 'severity', { type: DataTypes.INTEGER });
  }
}
```

---

## 26. Ensure Joi .or() / .xor() / .with() field names match actual schema properties

A typo in a `.or()` or `.xor()` clause (e.g., `'contact'` instead of `'contacts'`) silently disables the constraint. Joi does not error on unknown field names in these clauses — the validation simply never triggers.

**Bad implementation:**

```js
const schema = {
  body: Joi.object({
    contacts: Joi.array().items(
      Joi.object({
        /* ... */
      }),
    ),
    file: Joi.string().optional(),
  }).or("contact", "file"), // typo: 'contact' instead of 'contacts' — constraint is silently ignored
};
```

**Good implementation:**

```js
const schema = {
  body: Joi.object({
    contacts: Joi.array().items(
      Joi.object({
        /* ... */
      }),
    ),
    file: Joi.string().optional(),
  }).or("contacts", "file"), // correct field name — at least one must be provided
};
```

---

## 27. Apply access control filters to export/download endpoints too

When a listing endpoint applies access filters (e.g., visibility scoping, team restrictions), the corresponding export or CSV download endpoint must apply the exact same filters. Otherwise, the export becomes a bypass that leaks data the user shouldn't see.

**Bad implementation:**

```js
// Listing endpoint — properly filtered
async getSubTasks(user, query) {
  const filter = buildSubTaskAccessFilter(user);
  return findAll(SUBTASK, { ...query, ...filter });
}

// Export endpoint — missing the filter
async exportSubTasksCsv(user, query) {
  const tasks = await findAll(SUBTASK, query); // no access filter — data leak
  return convertToCsv(tasks);
}
```

**Good implementation:**

```js
// Listing endpoint
async getSubTasks(user, query) {
  const filter = buildSubTaskAccessFilter(user);
  return findAll(SUBTASK, { ...query, ...filter });
}

// Export endpoint — same filter applied
async exportSubTasksCsv(user, query) {
  const filter = buildSubTaskAccessFilter(user);
  const tasks = await findAll(SUBTASK, { ...query, ...filter });
  return convertToCsv(tasks);
}
```

---

## 28. Order authorization checks before data-existence checks to prevent info leaks

When an endpoint performs both an authorization check (e.g., team scope) and a data-existence check (e.g., contact lookup), always run the authorization check first. If a data-existence check runs first, different error messages reveal whether a resource exists to unauthorized callers.

**Bad implementation:**

```js
// validateCreate runs before beforeCreate — leaks contact existence to unauthorized users
validateCreate: async (user, body, lang) => {
  const contact = await findOne(CONTACT, { id: body.contact_id, user_id: body.user_id });
  if (!contact) {
    throw createError.BadRequest(msg.CONTACT_NOT_FOUND); // reveals (contact_id, user_id) pair validity
  }
},

beforeCreate: async (user, data, lang, transaction, req) => {
  if (!req.teamUserIds.includes(data.user_id)) {
    throw createError.Forbidden(msg.FORBIDDEN); // too late — info already leaked
  }
},
```

**Good implementation:**

```js
// beforeCreate runs the scope guard first, then checks contact existence
validateCreate: async (user, body, lang) => {
  if (new Date(body.scheduled_at) <= new Date()) {
    throw createError.BadRequest(msg.SCHEDULED_AT_MUST_BE_FUTURE);
  }
},

beforeCreate: async (user, data, lang, transaction, req) => {
  if (!req.teamUserIds.includes(data.user_id)) {
    throw createError.Forbidden(msg.FORBIDDEN); // authorization first
  }
  const contact = await findOne(CONTACT, { id: data.contact_id, user_id: data.user_id });
  if (!contact) {
    throw createError.BadRequest(msg.CONTACT_NOT_FOUND); // data check after authorization
  }
},
```

---

## 29. Restrict client-settable enum values to exclude system-managed states

When a Joi schema validates a status or type field against an enum, do not blindly use `Object.values(ENUM)`. If some values are system-managed (set by cron jobs, internal logic, or defaults), exclude them from the client-facing validator. Otherwise clients can set states that should only be reached through system processes.

**Bad implementation:**

```js
// Client can set status to SCHEDULED or OVERDUE, which should be system-managed
updateFields: {
  status: Joi.number()
    .valid(...Object.values(REMINDER_STATUS)) // includes SCHEDULED (0) and OVERDUE (3)
    .optional(),
},
```

**Good implementation:**

```js
// Only allow client-driven transitions (complete or cancel)
updateFields: {
  status: Joi.number()
    .valid(COMPLETED, CANCELLED) // SCHEDULED and OVERDUE are system-managed
    .optional(),
},
```

---

## 30. Write Migration for MySQL

The Database is on **MYSQL**. if the migrations are not written for this it wont work.

---

## 31. Keep API response payloads in snake_case to match the platform convention

All HTTP response payloads must use `snake_case` keys — the same casing as database columns and the rest of the public API. Mixing `camelCase` for new endpoints forces frontend consumers to handle two naming schemes and breaks shared serializers/typings. Transform only when absolutely necessary, and do it consistently.

**Bad implementation:**

```js
return rows.map((row) => {
  const plain = row.get({ plain: true });
  return {
    id: plain.id,
    actionType: plain.action_type,
    occurredAt: plain.occurred_at,
    previousStatus: plain.previous_status,
    newStatus: plain.new_status,
    businessOpportunity: plain.business_opportunity
      ? { id: plain.business_opportunity.id, name: buildName(plain.business_opportunity) }
      : null,
    contact: plain.contact
      ? { id: plain.contact.id, fullName: buildContactFullName(plain.contact) }
      : null,
  };
});
```

**Good implementation:**

```js
return rows.map((row) => {
  const plain = row.get({ plain: true });
  return {
    id: plain.id,
    action_type: plain.action_type,
    occurred_at: plain.occurred_at,
    previous_status: plain.previous_status,
    new_status: plain.new_status,
    business_opportunity: plain.business_opportunity
      ? { id: plain.business_opportunity.id, name: buildName(plain.business_opportunity) }
      : null,
    contact: plain.contact
      ? { id: plain.contact.id, full_name: buildContactFullName(plain.contact) }
      : null,
  };
});
```

---

## 32. Distinguish actor identity from owner identity for account-scoped ownership checks

On multi-user accounts (owner + staff/assistants), `user.id` is the caller making the request (actor), while `user.owner_id || user.id` is the logical owner of the account. Ownership checks on resources (group chats, customers, calendars) must compare against the **owner** identity so that staff can manage resources created by or for their owner. Using `user.id` alone locks staff out of their own account's data. Conversely, membership/participation lists must use the actor (so the staff member is actually added as a participant, not the owner).

**Bad implementation:**

```js
const updateGroupChat = async (user, id, body) => {
  const userId = user.id;
  const group = await getGroupChatById(user, id);

  // Staff member can never pass this check on a group owned by their account owner
  if (group.owner_group.id !== userId) {
    throw createError.BadRequest(YOU_ARE_NOT_THE_GROUP);
  }

  if (!members.includes(userId)) {
    members.push(userId);
  }
};
```

**Good implementation:**

```js
const updateGroupChat = async (user, id, body) => {
  const actorId = user.id;
  const ownerId = user.owner_id || actorId;
  const group = await getGroupChatById(user, id);

  // Ownership is checked against the account owner
  if (group.owner_group.id !== ownerId) {
    throw createError.BadRequest(YOU_ARE_NOT_THE_GROUP);
  }

  // Participation uses the actor so the staff member is the one added to the group
  if (!members.includes(actorId)) {
    members.push(actorId);
  }
};
```

---

## 33. Guard each migration step independently, not the whole migration

A single outer `if (!column_exists)` around an entire multi-step migration is fragile: if the column is added but the backfill, NOT NULL conversion, or FK constraint fails, the next run will see the column and skip every remaining step, leaving the DB permanently in a half-applied state. Re-read the table state between steps and guard each DDL operation with its own precondition check so re-runs converge to the target state.

**Bad implementation:**

```js
async up(queryInterface) {
  const tableDescription = await queryInterface.describeTable(REMINDER);

  if (!tableDescription.customer_id) {
    await queryInterface.sequelize.query(`ALTER TABLE ${REMINDER} ADD COLUMN customer_id CHAR(36) NULL`);
    await queryInterface.sequelize.query(`UPDATE ${REMINDER} r INNER JOIN ${CONTACT} c ON c.id = r.contact_id SET r.customer_id = c.customer_id`);
    await queryInterface.sequelize.query(`DELETE FROM ${REMINDER} WHERE customer_id IS NULL`);
    // If any earlier step fails, these never run on retry because the column already exists
    await queryInterface.sequelize.query(`ALTER TABLE ${REMINDER} MODIFY COLUMN customer_id CHAR(36) NOT NULL, ADD CONSTRAINT reminders_customer_id_foreign_idx FOREIGN KEY (customer_id) REFERENCES ${CUSTOMER}(id)`);
  }
}
```

**Good implementation:**

```js
async up(queryInterface) {
  const initial = await queryInterface.describeTable(REMINDER);

  if (!initial.customer_id) {
    await queryInterface.sequelize.query(`ALTER TABLE ${REMINDER} ADD COLUMN customer_id CHAR(36) NULL`);
  }

  // Backfill is idempotent (WHERE customer_id IS NULL) — always safe to re-run
  await queryInterface.sequelize.query(
    `UPDATE ${REMINDER} r INNER JOIN ${CONTACT} c ON c.id = r.contact_id
     SET r.customer_id = c.customer_id WHERE r.customer_id IS NULL`
  );

  const afterBackfill = await queryInterface.describeTable(REMINDER);
  if (afterBackfill.customer_id && afterBackfill.customer_id.allowNull !== false) {
    await queryInterface.sequelize.query(`ALTER TABLE ${REMINDER} MODIFY COLUMN customer_id CHAR(36) NOT NULL`);
  }

  const [existingFk] = await queryInterface.sequelize.query(
    `SELECT CONSTRAINT_NAME FROM information_schema.KEY_COLUMN_USAGE
     WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = '${REMINDER}'
       AND CONSTRAINT_NAME = 'reminders_customer_id_foreign_idx'`
  );
  if (!existingFk.length) {
    await queryInterface.sequelize.query(
      `ALTER TABLE ${REMINDER} ADD CONSTRAINT reminders_customer_id_foreign_idx
       FOREIGN KEY (customer_id) REFERENCES ${CUSTOMER}(id) ON UPDATE CASCADE ON DELETE CASCADE`
    );
  }
}
```

---

## 34. Destructive down migrations must refuse to run when data would be lost

A `down` migration that silently deletes rows to revert a schema change (e.g., `DELETE FROM reminders WHERE contact_id IS NULL` to restore a NOT NULL constraint) destroys data the operator may not expect to lose. Instead, count the rows that would be deleted and throw a descriptive error telling the operator to resolve them manually. Rollbacks should be safe by default.

**Bad implementation:**

```js
async down(queryInterface, Sequelize) {
  if (tableDescription.contact_id && tableDescription.contact_id.allowNull === true) {
    await queryInterface.sequelize.query(`DELETE FROM ${REMINDER} WHERE contact_id IS NULL`); // silent data loss
    await queryInterface.changeColumn(REMINDER, 'contact_id', { type: Sequelize.INTEGER, allowNull: false });
  }
}
```

**Good implementation:**

```js
async down(queryInterface, Sequelize) {
  if (tableDescription.contact_id && tableDescription.contact_id.allowNull === true) {
    const [[{ n }]] = await queryInterface.sequelize.query(
      `SELECT COUNT(*) AS n FROM ${REMINDER} WHERE contact_id IS NULL`
    );
    if (Number(n) > 0) {
      throw new Error(
        `[Migration 189 down] Refusing to delete ${n} reminders with contact_id IS NULL. Resolve manually before rolling back.`
      );
    }
    await queryInterface.changeColumn(REMINDER, 'contact_id', { type: Sequelize.INTEGER, allowNull: false });
  }
}
```

---

## 35. Keep Sequelize model types in sync with the underlying column type

When a migration creates a column as `CHAR(36)` (UUID), the Sequelize model definition must declare `DataTypes.UUID`, not `DataTypes.INTEGER`. A type mismatch is silently accepted by Sequelize at model-load time but corrupts inserts, breaks foreign key joins, and produces confusing runtime errors. Whenever a migration changes a column type, update the model in the same PR.

**Bad implementation:**

```js
// Migration adds CHAR(36) (UUID)
await queryInterface.sequelize.query(
  `ALTER TABLE ${REMINDER} ADD COLUMN customer_id CHAR(36) CHARACTER SET utf8mb3 COLLATE utf8mb3_bin NULL`
);

// Model still declares INTEGER — type drift
module.exports = (sequelize, DataTypes) => sequelize.define('reminder', {
  customer_id: {
    type: DataTypes.INTEGER, // WRONG — column is a UUID
    allowNull: false,
  },
});
```

**Good implementation:**

```js
// Model matches the migration's CHAR(36) UUID column
module.exports = (sequelize, DataTypes) => sequelize.define('reminder', {
  customer_id: {
    type: DataTypes.UUID,
    allowNull: false,
  },
});
```

---

## 36. Do not open a transaction for a single atomic statement

A transaction that wraps exactly one SQL statement adds no atomicity guarantee (single statements are already atomic) but does add overhead, extra failure modes (commit/rollback branching), and noise. Only open a transaction when two or more writes must succeed or fail together.

**Bad implementation:**

```js
const viewAllNotification = async (user) => {
  const t = await sequelize.transaction();
  try {
    await updateWhere(
      NOTIFICATION,
      { user_id: user.id, already_read: false },
      { already_read: true },
      t
    );
    await t.commit();
    return { message: UPDATE_SUCCESS };
  } catch (error) {
    await t.rollback();
    throw error;
  }
};
```

**Good implementation:**

```js
const viewAllNotification = async (user) => {
  try {
    await updateWhere(
      NOTIFICATION,
      { user_id: user.id, already_read: false },
      { already_read: true }
    );
    return { message: UPDATE_SUCCESS };
  } catch (error) {
    console.error('viewAllNotification error', error);
    throw error;
  }
};
```

## Batch associated lookups with a single findAll instead of Promise.all + findOne

When enriching a list of rows with related data, issuing one query per item (even in parallel with Promise.all) is an N+1 pattern: it multiplies round-trips, saturates the pool and scales poorly. Collect the foreign keys, issue one `findAll` with `{ [Op.in]: ids }`, and index the result by key in a Map. Order the query so the first row per key wins (e.g. most recent), and keep only the first occurrence when populating the Map.

**Bad implementation:**

```js
const boByCustomerId = new Map();
await Promise.all(
  customerIds.map(async (customerId) => {
    const bo = await models[BUSINESS_OPPORTUNITY].findOne({
      where: {
        customer_id: customerId,
        status: { [Op.in]: BO_POSITIVE_STATUSES },
      },
      attributes: ['id', 'contact'],
      order: [['updated_at', 'DESC']],
    });
    if (bo) boByCustomerId.set(customerId, bo);
  })
);
```

**good implementation**

```js
const boByCustomerId = new Map();
if (customerIds.length) {
  const boRows = await models[BUSINESS_OPPORTUNITY].findAll({
    where: {
      customer_id: { [Op.in]: customerIds },
      status: { [Op.in]: BO_POSITIVE_STATUSES },
    },
    attributes: ['id', 'customer_id', 'updated_at'],
    include: [
      { model: models[PRODUCT], required: false, attributes: ['id', 'name'] },
      { model: models[CUSTOMER], required: false, attributes: ['id', 'company_name'] },
    ],
    order: [
      ['customer_id', 'ASC'],
      ['updated_at', 'DESC'],
      ['id', 'DESC'],
    ],
  });
  for (const bo of boRows) {
    if (!boByCustomerId.has(bo.customer_id)) boByCustomerId.set(bo.customer_id, bo);
  }
}
```

## Read foreign keys from the owning row, not through an optional association

When a column lives directly on the parent row (NOT NULL, its own column), use it. Reaching through an included association to get the same FK forces an INNER JOIN, silently drops rows whose association is nullable/missing, and couples the query to a relation you may not even need. Query the own column and make the include a LEFT JOIN so optional related entities do not filter out valid rows.

**Bad implementation:**

```js
const reminders = await models[REMINDER].findAll({
  where: { /* ... */ },
  include: [
    {
      model: models[CONTACT],
      required: true, // INNER JOIN: drops contactless reminders
      attributes: ['id', 'first_name', 'last_name', 'customer_id'],
    },
  ],
});

const customerIds = [
  ...new Set(reminders.map((r) => r.contact?.customer_id).filter(Boolean)),
];
// ...
const bo = contact?.customer_id ? boByCustomerId.get(contact.customer_id) : null;
```

**good implementation**

```js
const reminders = await models[REMINDER].findAll({
  where: { /* ... */ },
  include: [
    {
      model: models[CONTACT],
      required: false, // LEFT JOIN: contactless reminders still returned
      attributes: ['id', 'first_name', 'last_name'],
    },
  ],
});

// customer_id is NOT NULL on reminder itself — read it directly
const customerIds = [...new Set(reminders.map((r) => r.customer_id).filter(Boolean))];
// ...
const bo = r.customer_id ? boByCustomerId.get(r.customer_id) : null;
```

## Scope authenticated queries to req.authUserId, not req.user

`req.user` is whatever the auth middleware loaded (often the account owner, an impersonated user, or a shared context), and its columns are only the ones that middleware happened to select. Persisted scoping (session owner, goal, "my" filters) must use `req.authUserId` so staff/sub-users see their own data, not the owner's. Avoid reading fields off `req.user` that do not exist on the model (e.g. `user.timezone` when USER has no such column) — silent `undefined` then falls through to a default and masks the bug.

**Bad implementation:**

```js
// controller
const result = await paymentService.getDailyCallsKpi(req.user, req.query);

// service
const getDailyCallsKpi = async (user, query = {}) => {
  const timezone = query.timezone || user.timezone || TIMEZONE; // user.timezone does not exist
  // ...
  where: { user_id: user.id }, // scopes to owner, not the caller
  // ...
  where: { user_id: user.id, year: moment().tz(timezone).year() },
};
```

**good implementation**

```js
// controller
const result = await paymentService.getDailyCallsKpi(req.authUserId, req.query);

// service
const getDailyCallsKpi = async (authUserId, query = {}) => {
  const timezone = query.timezone || TIMEZONE;
  // ...
  where: { user_id: authUserId },
  // ...
  where: { user_id: authUserId, year: moment().tz(timezone).year() },
};
```

## Match response casing to the convention of sibling endpoints

Within one API surface (e.g. a dashboard namespace), response keys should follow a single casing convention. Mixing `camelCase` into an otherwise `snake_case` family forces the frontend to special-case individual endpoints and is a common review finding. Before shipping a new endpoint, check a sibling response and match it — including nested objects.

**Bad implementation:**

```js
return {
  id: r.id,
  type: r.type,
  scheduledAt: r.scheduled_at,
  contact: contact ? { id: contact.id, fullName } : null,
  businessOpportunity: bo ? { id: bo.id, name: bo.contact || null } : null,
};

// and, in a sibling KPI:
return { total, positive, negative, dailyGoal, progressPercent };
```

**good implementation**

```js
return {
  id: r.id,
  type: r.type,
  scheduled_at: r.scheduled_at,
  contact: contact ? { id: contact.id, full_name: buildContactFullName(contact) } : null,
  business_opportunity: bo ? { id: bo.id, name: buildBusinessOpportunityName(bo) } : null,
};

// sibling KPI, same convention:
return { total, positive, negative, daily_goal: dailyGoal, progress_percent: progressPercent };
```
