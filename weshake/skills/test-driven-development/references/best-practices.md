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

---

## Validate required environment variables at the use site

When a code path depends on an env var (webhook URL, API key, bucket name) and a missing value would silently produce a malformed URL or a 4xx from an external API, assert it at the use site and throw a clear error. `${process.env.PLATFORM_API_URL}/api/v1/...` becomes `"undefined/api/v1/..."` if the var is missing — the call to the external service then fails with a confusing 404 hours later. Fail fast with the variable name in the message instead.

**Bad implementation:**

```js
const webhookUrl = `${process.env.PLATFORM_API_URL}/api/v1/onboarding/webhooks`;
const personPayload = OnboardingAPI.createPersonPayload(employee, ownerDocReg.onboarding_id, true, true);
await OnboardingAPI.startVerification(personPayload, webhookUrl);
```

**Good implementation:**

```js
if (!process.env.PLATFORM_API_URL) {
  throw createError.InternalServerError('PLATFORM_API_URL environment variable is not defined');
}

const webhookUrl = `${process.env.PLATFORM_API_URL}/api/v1/onboarding/webhooks`;
const personPayload = OnboardingAPI.createPersonPayload(employee, ownerDocReg.onboarding_id, true, true);
await OnboardingAPI.startVerification(personPayload, webhookUrl);
```

---

## Make webhook processing idempotent by short-circuiting when stored state already matches

Webhooks are retried by providers (often multiple times within seconds). If a handler downloads documents, calls external APIs, or writes side effects, re-applying the same payload wastes resources and can race against itself. Before doing any work, compare the incoming status with the persisted one and return an `already_processed` acknowledgement when they match.

**Bad implementation:**

```js
const targetUser = await AdminUserService.getUser(documentRegistration.user_id, lang);
const statusLower = status.toLowerCase();
// Always re-downloads docs and rewrites the row, even if status hasn't changed
const documentsToStore = await this._downloadDocuments(verificationId);
await this._updateRegistration(documentRegistration, { docv_verification_status: statusLower, ...documentsToStore });
```

**Good implementation:**

```js
const statusLower = status.toLowerCase();

if ((documentRegistration.docv_verification_status || '').toLowerCase() === statusLower) {
  return { success: true, status: 'already_processed', verification_id: verificationId };
}

const targetUser = await AdminUserService.getUser(documentRegistration.user_id, lang);
const documentsToStore = await this._downloadDocuments(verificationId);
await this._updateRegistration(documentRegistration, { docv_verification_status: statusLower, ...documentsToStore });
```

---

## Use the structured logger with context metadata, not console.error string concatenation

`console.error('Failed to do X:', err)` produces an unstructured, ungrep-able line and loses request context. Use the project logger with a static message and a metadata object so logs are queryable by field (employeeId, error.message, stack) in the aggregator.

**Bad implementation:**

```js
console.error('Onboarding started but no DOCV verification id returned for employee:', employee.id);
// ...
requestEmitSocket(notificationData).catch((err) =>
  console.error('Failed to emit DOCV upload required notification:', err)
);
// ...
console.error('Webhook processing failed:', error);
```

**Good implementation:**

```js
const logger = require('../../helpers/logger.helper');

logger.error('Onboarding started but no DOCV verification id returned for employee', { employeeId: employee.id });
// ...
requestEmitSocket(notificationData).catch((err) =>
  logger.error('Failed to emit DOCV upload required notification', { error: err.message })
);
// ...
logger.error('Webhook processing failed', { error: error?.message, stack: error?.stack });
```

---

## Do not leak internal error messages in HTTP responses

When an endpoint catches an exception and returns an error payload, log the details server-side but keep the HTTP body generic. Echoing `error.message` (or `error.stack`) to the caller leaks DB column names, file paths, library internals, and SQL — useful for attackers and noisy for legitimate clients.

**Bad implementation:**

```js
} catch (error) {
  logger.error('Webhook processing failed', { error: error?.message, stack: error?.stack });
  return res.status(500).json({
    success: false,
    error: 'Webhook processing failed',
    detail: error?.message, // leaks internal info
  });
}
```

**Good implementation:**

```js
} catch (error) {
  logger.error('Webhook processing failed', { error: error?.message, stack: error?.stack });
  return res.status(500).json({
    success: false,
    error: 'Webhook processing failed',
  });
}
```

---

## Restrict file-upload MIME allowlists to canonical IANA types

`image/jpg` is not a valid MIME type — the IANA-registered value is `image/jpeg`. Some browsers/clients send the non-canonical form, but accepting both invites bypasses (a hostile client can claim `image/jpg` to skip stricter `image/jpeg` checks elsewhere). Accept only the canonical type and rely on the extension allowlist for `.jpg` files.

**Bad implementation:**

```js
const allowedTypes = ['image/jpeg', 'image/png', 'image/jpg', 'application/pdf'];
const allowedExtensions = ['.jpg', '.jpeg', '.png', '.pdf'];
```

**Good implementation:**

```js
const allowedTypes = ['image/jpeg', 'image/png', 'application/pdf'];
const allowedExtensions = ['.jpg', '.jpeg', '.png', '.pdf'];
```

---

## Normalize external string values before storing and comparing

External providers may send the same status with inconsistent casing (`"COMPLETED"`, `"Completed"`, `"completed"`). Storing the raw value and comparing against a lowercase enum produces false negatives in idempotency checks and breaks downstream switches. Lowercase (or uppercase) once at the boundary, then store and compare on the normalized form.

**Bad implementation:**

```js
const statusLower = status.toLowerCase();
// ... compare lowercase against stored mixed-case value:
if (documentRegistration.docv_verification_status === statusLower) { /* never matches if stored "Completed" */ }
// ... but persist the original casing:
await update(REGISTRATION, { id }, { docv_verification_status: status });
```

**Good implementation:**

```js
const statusLower = status.toLowerCase();
if ((documentRegistration.docv_verification_status || '').toLowerCase() === statusLower) {
  return { success: true, status: 'already_processed' };
}
// Persist the normalized form so future comparisons line up
await update(REGISTRATION, { id }, { docv_verification_status: statusLower });
```

---

## Tighten free-string ID validators with a character pattern and a max length

`Joi.string().required()` on an external ID accepts arbitrary content of any length — newlines, control characters, 1 MB strings. When the ID flows into a URL path, an external API call, or a `LIKE` query, this is a vector for path traversal, header injection, and DoS. Constrain external IDs to the alphabet the provider actually emits and cap the length.

**Bad implementation:**

```js
const schemaDocvByIdParams = {
  params: Joi.object({
    id: Joi.string().required(),
  }),
};
```

**Good implementation:**

```js
const schemaDocvByIdParams = {
  params: Joi.object({
    id: Joi.string()
      .pattern(/^[a-zA-Z0-9_-]+$/)
      .max(255)
      .required(),
  }),
};
```

---

## Derive sub-user access rights from the owner's modules, not the global permission catalog

When provisioning a staff/employee user, the access-rights object must only contain the modules the **owner** has subscribed to. Iterating over the global `ROLE_PERMISSION_FIELDS` catalog grants flags for modules the account does not have — the row will carry `weshake_card: false` even on plans without the card module, masking later activations and corrupting admin views. Iterate over `getModulesForUser(ownerUser)` so the shape mirrors the owner's surface.

**Bad implementation:**

```js
const buildDashboardOnlyAccessRights = () => {
  const accessRights = {};
  for (const field of ROLE_PERMISSION_FIELDS) { // every flag in the global catalog
    accessRights[field] = field === 'dashboard';
  }
  return accessRights;
};

const buildAccessRightsFromRole = (role, ownerUser) => {
  const ownerModules = getModulesForUser(ownerUser);
  const accessRights = {};
  for (const field of ROLE_PERMISSION_FIELDS) {
    if (ownerModules.includes(field)) {
      accessRights[field] = role[field] === true;
    }
  }
  return accessRights;
};
```

**Good implementation:**

```js
const buildDashboardOnlyAccessRights = (ownerUser) => {
  const ownerModules = getModulesForUser(ownerUser);
  const accessRights = {};
  for (const field of ownerModules) {
    accessRights[field] = field === 'dashboard';
  }
  return accessRights;
};

const buildAccessRightsFromRole = (role, ownerUser) => {
  const ownerModules = getModulesForUser(ownerUser);
  const accessRights = {};
  for (const field of ownerModules) {
    accessRights[field] = role[field] === true;
  }
  return accessRights;
};
```

---

## Centralize cross-module flag/enum lists in a shared constant

Hardcoding a long array of permission flags (or any enum-like list) at the top of a validator file means the next time the catalog grows, two locations must be updated and inevitably drift. Move the list to `appConst` (or a shared module) and import it everywhere. Drift here silently disables validation for the new flags.

**Bad implementation:**

```js
// validator.role.js
const PERMISSION_FLAGS = [
  'account', 'setting', 'chat', 'formula', 'dashboard', 'customers', 'suppliers',
  'products', 'quotations', 'invoices', 'credit_notes', 'subscription', 'presentation',
  'find_individual', 'connections', 'campaigns', 'social_risk', 'balance', 'statement',
  'transfers', 'beneficiary', 'weshake_card', 'rib', 'call_manager',
];

const PERMISSION_FIELDS_SCHEMA = Object.fromEntries(
  PERMISSION_FLAGS.map((flag) => [flag, Joi.boolean().allow(null).optional()])
);
```

**Good implementation:**

```js
// validator.role.js
const { ROLE_PERMISSION_FIELDS } = appConst;

const PERMISSION_FIELDS_SCHEMA = Object.fromEntries(
  ROLE_PERMISSION_FIELDS.map((flag) => [flag, Joi.boolean().allow(null).optional()])
);
```

---

## Layer a coarse audience guard alongside fine-grained permission checks

`permitStaffRole('setting')` checks whether the caller has the `setting` permission, but it does not verify the caller is actually a staff/admin user — a regular user with a hand-crafted role could pass it. For sensitive endpoints (role create/delete, settings, billing), add a coarse `requireStaff` middleware **before** the permission check so non-staff requests are rejected even if their role flags somehow line up. Defense in depth.

**Bad implementation:**

```js
router.post(
  '/',
  asyncMiddleware(checkLogin),
  asyncMiddleware(verifyUserToken),
  asyncMiddleware(verifyPlatformToken),
  permitStaffRole('setting'), // only checks the permission flag, not the staff bit
  validate(schema_createRole),
  asyncMiddleware(createRole),
);
```

**Good implementation:**

```js
const requireStaff = (req, res, next) => {
  const lang = req.lang || appConst.HEADER.LOCALE_DEFAULT;
  if (!req.user?.staff) {
    throw createApiError(403, commonMessage(lang).YOU_DO_NOT_HAVE_ACCESS_TRANSMISSION, ERROR_CODE.STAFF_PERMISSION_DENIED);
  }
  next();
};

router.post(
  '/',
  asyncMiddleware(checkLogin),
  asyncMiddleware(verifyUserToken),
  asyncMiddleware(verifyPlatformToken),
  requireStaff,                  // coarse audience guard first
  permitStaffRole('setting'),    // then fine-grained permission
  validate(schema_createRole),
  asyncMiddleware(createRole),
);
```

---

## Map intermediate "awaiting review" provider statuses to null, not to a binary outcome

When mapping a provider's screening/verification result to a UI-facing `clean | flagged` value, an intermediate state like `REQUIRES_REVIEW` must NOT collapse to `flagged`. Returning `flagged` for a row that is still being reviewed triggers downstream "onboarding failed" logic and locks users out. Map the intermediate state to `null` (unknown / pending) and only emit `clean | flagged` once the provider has actually decided.

**Bad implementation:**

```js
// `requires_review` is truthy, so `screening.result ? ... : null` falls into the ternary
const screeningResult = screening.result ? (screening.isClean ? 'clean' : 'flagged') : null;

return {
  // ...
  is_onboarding_failed: identityStatus === 'failed' || screeningResult === 'flagged', // false-positive failure
};
```

**Good implementation:**

```js
const isAwaitingReview = screening.result === COMPLY_ADVANTAGE.SCREENING_RESULTS.REQUIRES_REVIEW;
const screeningResult = !screening.result || isAwaitingReview
  ? null
  : screening.isClean ? 'clean' : 'flagged';

return {
  // ...
  is_onboarding_failed: identityStatus === 'failed' || screeningResult === 'flagged',
};
```

---

## Reuse a single Joi schema object for routes that share the same params shape

When multiple routes accept the exact same params (typically `{ id }`), define one schema and export it under both names instead of duplicating the literal. Duplication invites drift — one route gets `Joi.number().integer().positive()` tightened to a UUID while the other keeps the integer rule, and only a code reviewer catches it.

**Bad implementation:**

```js
module.exports.schemaGetEmployeeById = {
  params: Joi.object({
    id: Joi.number().integer().positive().required(),
  }),
};

module.exports.schemaGetCardOnboardingStatus = {
  params: Joi.object({
    id: Joi.number().integer().positive().required(),
  }),
};
```

**Good implementation:**

```js
const idParamsSchema = {
  params: Joi.object({
    id: Joi.number().integer().positive().required(),
  }),
};

module.exports.schemaGetEmployeeById = idParamsSchema;
module.exports.schemaGetCardOnboardingStatus = idParamsSchema;
```

---

## Use the shared timezone constant instead of hardcoded "Europe/Paris"

The codebase exposes `appConst.TIMEZONE` as the single source of truth for the default timezone. Files that redeclare `const DEFAULT_TIMEZONE = 'Europe/Paris'` drift from that source the day the platform expands to a new region, and the affected module silently keeps computing call windows / KPIs in the old zone. Always pull from the shared constant.

**Bad implementation:**

```js
const DEFAULT_TIMEZONE = 'Europe/Paris';

const getNowForUser = (user) => moment.tz(user?.timezone || DEFAULT_TIMEZONE);
```

**Good implementation:**

```js
const DEFAULT_TIMEZONE = appConst.TIMEZONE;

const getNowForUser = (user) => moment.tz(user?.timezone || DEFAULT_TIMEZONE);
```

---

## Do not duplicate list-level metadata on every row of a paginated response

If a value is the same for every row in a paginated response (e.g. the queue's `total`, the user's `quota`), it is metadata, not row data. Returning it on each row inflates the payload, encourages frontends to read it from an arbitrary row (which breaks on empty pages), and forces the docs/schema to describe it twice. Put it once on the response envelope and remove it from the row schema.

**Bad implementation:**

```json
{
  "items": [
    { "id": 1, "position": 1, "total": 42 },
    { "id": 2, "position": 2, "total": 42 },
    { "id": 3, "position": 3, "total": 42 }
  ],
  "page": 1,
  "limit": 10
}
```

**Good implementation:**

```json
{
  "items": [
    { "id": 1, "position": 1 },
    { "id": 2, "position": 2 },
    { "id": 3, "position": 3 }
  ],
  "total": 42,
  "page": 1,
  "limit": 10
}
```


---

## Match Joi param validators to the actual primary-key type

A Joi `params` validator must mirror the column type the route's `:id` actually maps to. Copying `Joi.string().length(36).required()` (or `.uuid()`) onto a route whose target table uses an auto-increment integer makes every authenticated call return `400 "id length must be 36 characters long"`. The framework's default detail validator is permissive enough to hide the mismatch on standard CRUD routes, but `customRoutes` skip that default — so a hardcoded UUID rule on a custom route silently breaks production. Before adding a `params` validator to a `customRoutes` entry, open the corresponding model and check whether the primary key is `DataTypes.UUID` (CHAR(36)) or `DataTypes.INTEGER` and pick the matching Joi shape. Bonus: integration-test the new endpoint against a row created by the same suite — that's the only way the local manual run catches the type drift.

**Bad implementation:**

```js
// src/module/contact/index.js — contacts.id is INTEGER autoIncrement
customRoutes: [{
  method: 'get',
  path: '/:id/duplicates',
  handler: getContactDuplicates,
  validator: { params: Joi.object({ id: Joi.string().length(36).required() }) }, // every call → 400
}],
```

**Good implementation:**

```js
// src/module/contact/index.js — match the model's INTEGER primary key
customRoutes: [{
  method: 'get',
  path: '/:id/duplicates',
  handler: getContactDuplicates,
  validator: { params: Joi.object({ id: Joi.number().integer().positive().required() }) },
}],
```

---

## Make the displayed total equal the sum of its displayed parts

When a response exposes both an aggregate score and the per-component breakdown that produced it, accumulate the **rounded** part values into the total — do not round the total separately from the parts. Otherwise users see `score = 87` while `sum(components.score) = 86` because the total was rounded from raw `rate * weight * MAX` floats while each part was rounded independently. Discrepancies of 1–2 points across components erode trust in the metric and break frontend assertions like "score equals the sum of the bars".

**Bad implementation:**

```js
const buildDailyScoreComponents = (counts, goals, weights) => {
  let scoreSum = 0;
  for (const c of items) {
    const rate = isActive ? Math.min(1, c.done / c.goal) : 0;
    const partScore = Math.round(rate * normalizedWeight * DAILY_SCORE_MAX);
    scoreSum += rate * normalizedWeight * DAILY_SCORE_MAX; // raw float, not partScore
    components[key] = { ...c, score: partScore };
  }
  return { components, score: Math.round(scoreSum) }; // diverges from sum(components.score)
};
```

**Good implementation:**

```js
const buildDailyScoreComponents = (counts, goals, weights) => {
  let scoreSum = 0;
  for (const c of items) {
    const rate = isActive ? Math.min(1, c.done / c.goal) : 0;
    const partScore = Math.round(rate * normalizedWeight * DAILY_SCORE_MAX);
    scoreSum += partScore; // accumulate the rounded value the user actually sees
    components[key] = { ...c, score: partScore };
  }
  return { components, score: scoreSum };
};
```

---

## Hoist loop-invariant lookups out of map/Promise.all bodies

When every iteration of a loop calls a function whose result does not depend on the iteration variable (e.g. `getDailyScoreWeights(authUserId)` inside a per-team-member map), the function is invoked N times for the same answer. Compute it once before the loop and pass the resolved value into each iteration. This is distinct from the N+1 pattern: the lookup is not parameterized by the row, it is genuinely constant for the request, and yet a naive implementation still issues N reads against the same row in `crm_settings`.

**Bad implementation:**

```js
const entries = await Promise.all(
  teamUsers.map(async (member) => {
    // getDailyScoreWeights(authUserId) hits CRM_SETTING once per member — same row, N times
    const { components, score } = await computeDailyScoreForUser(member.id, authUserId, day);
    return { user_id: member.id, score, components };
  }),
);
```

**Good implementation:**

```js
const [teamUsers, weightsResolved] = await Promise.all([
  models[USER].findAll({ where: { owner_id: authUserId }, attributes: ['id', 'first_name', 'last_name'] }),
  getDailyScoreWeights(authUserId), // resolved once, reused in every iteration
]);

const entries = await Promise.all(
  teamUsers.map(async (member) => {
    const { components, score } = await computeDailyScoreForUser(member.id, weightsResolved.weights, day);
    return { user_id: member.id, score, components };
  }),
);
```

---

## Clamp DB-loaded numeric ranges at the read site as defense in depth

A validator that caps weights / ratios / probabilities to `[0, 1]` only protects values written through the validated route. Rows persisted before the validator existed, written by a sibling job, edited via the admin DB console, or migrated from another source can still hold `2`, `-3`, or `NaN`. When the read path multiplies these by `MAX_SCORE` it produces nonsense. Re-clamp at the read boundary so the consumer cannot be poisoned by historical or out-of-band writes — and so future relaxations of the validator do not silently corrupt scores.

**Bad implementation:**

```js
return {
  calls: Number(stored.calls ?? DAILY_SCORE_DEFAULT_WEIGHTS.calls),       // could be 2 or NaN
  reminders: Number(stored.reminders ?? DAILY_SCORE_DEFAULT_WEIGHTS.reminders),
  qualified: Number(stored.qualified ?? DAILY_SCORE_DEFAULT_WEIGHTS.qualified),
};
```

**Good implementation:**

```js
const clampWeight = (raw, fallback) => {
  const n = Number(raw);
  if (!Number.isFinite(n)) { return fallback; }
  return Math.max(0, Math.min(1, n));
};

return {
  calls: clampWeight(stored.calls, DAILY_SCORE_DEFAULT_WEIGHTS.calls),
  reminders: clampWeight(stored.reminders, DAILY_SCORE_DEFAULT_WEIGHTS.reminders),
  qualified: clampWeight(stored.qualified, DAILY_SCORE_DEFAULT_WEIGHTS.qualified),
};
```

---

## Validate timezone strings against an actual tz database, not just length

A `Joi.string().trim().max(50)` accepts `"Mars/Olympus"`, `"Europe/Paaaaaris"`, or any garbage shorter than 50 chars. When that value is later passed to `moment.tz()`, moment silently falls back to UTC, computing the day window in the wrong zone and skewing every "today" KPI for that request. Validate the input against the IANA tz database at the validator boundary using `momentTz.tz.zone(value)` (returns null for unknown zones) so bad values are rejected with `400 timezone_invalid` instead of producing wrong-but-plausible numbers downstream.

**Bad implementation:**

```js
const dailyScoreBaseQuery = Joi.object({
  date: Joi.string().pattern(YYYY_MM_DD).optional(),
  timezone: Joi.string().trim().max(50).optional(), // accepts any short string
});
```

**Good implementation:**

```js
const momentTz = require('moment-timezone');

const dailyScoreBaseQuery = Joi.object({
  date: Joi.string().pattern(YYYY_MM_DD).optional(),
  timezone: Joi.string()
    .trim()
    .max(50)
    .custom((value, helpers) => (momentTz.tz.zone(value) ? value : helpers.message('timezone_invalid')))
    .optional(),
});
```

---

## Reject future dates on "today/past" KPI endpoints at the validator

KPI endpoints that compute "what happened on day X" are only meaningful when X is today or earlier — a future date produces an empty window and a misleading 0/100 score. Catching this in the controller wastes a round-trip and risks inconsistent error shapes. Add an `isNotFutureDate` predicate to the date validator so the route returns `400 date_in_future` before any DB work, and so the contract is documented in the schema itself.

**Bad implementation:**

```js
date: Joi.string()
  .pattern(YYYY_MM_DD)
  .custom((value, helpers) => (isValidCalendarDate(value) ? value : helpers.message('date_invalid')))
  .optional(),
// Caller can request 2099-01-01 and gets back score: 0 with no error
```

**Good implementation:**

```js
const isNotFutureDate = (value) => value <= new Date().toISOString().slice(0, 10);

date: Joi.string()
  .pattern(YYYY_MM_DD)
  .custom((value, helpers) => {
    if (!isValidCalendarDate(value)) { return helpers.message('date_invalid'); }
    if (!isNotFutureDate(value)) { return helpers.message('date_in_future'); }
    return value;
  })
  .optional(),
```

---

## Return the real provenance of a value, never a hardcoded label

When a response advertises where a value came from (e.g. `weights_source: 'crm_setting'`, `pricing_source: 'plan_override'`), that field must reflect the **actual** branch taken at runtime. Hardcoding the "happy path" label is worse than omitting the field: it lies to the frontend and to support engineers debugging "why are my custom weights not applied" — they read `crm_setting` and stop investigating, even though defaults were silently used because the row was missing or the user was unauthenticated. Compute the source alongside the value and return it.

**Bad implementation:**

```js
const getDailyScoreWeights = async (masterUserId) => {
  if (!masterUserId) { return { ...DAILY_SCORE_DEFAULT_WEIGHTS }; } // defaults
  const setting = await models[CRM_SETTING].findOne({ where: { user_id: masterUserId } });
  if (!setting?.daily_score_weights) { return { ...DAILY_SCORE_DEFAULT_WEIGHTS }; } // defaults
  return { /* stored values */ };
};

// controller
return { /* ... */, weights_source: 'crm_setting' }; // lies in two of the three branches
```

**Good implementation:**

```js
const getDailyScoreWeights = async (masterUserId) => {
  if (!masterUserId) { return { weights: { ...DAILY_SCORE_DEFAULT_WEIGHTS }, source: 'default' }; }
  const setting = await models[CRM_SETTING].findOne({ where: { user_id: masterUserId } });
  const stored = setting?.daily_score_weights;
  if (!stored) { return { weights: { ...DAILY_SCORE_DEFAULT_WEIGHTS }, source: 'default' }; }
  return { weights: { /* stored values */ }, source: 'crm_setting' };
};

// controller
const { weights, source } = await getDailyScoreWeights(user.id);
return { /* ... */, weights_source: source };
```

**Bad implementation:**

```js
const getDailyScoreWeights = async (masterUserId) => {
  if (!masterUserId) { return { ...DAILY_SCORE_DEFAULT_WEIGHTS }; } // defaults
  const setting = await models[CRM_SETTING].findOne({ where: { user_id: masterUserId } });
  if (!setting?.daily_score_weights) { return { ...DAILY_SCORE_DEFAULT_WEIGHTS }; } // defaults
  return { /* stored values */ };
};

// controller
return { /* ... */, weights_source: 'crm_setting' }; // lies in two of the three branches
```

**Good implementation:**

```js
const getDailyScoreWeights = async (masterUserId) => {
  if (!masterUserId) { return { weights: { ...DAILY_SCORE_DEFAULT_WEIGHTS }, source: 'default' }; }
  const setting = await models[CRM_SETTING].findOne({ where: { user_id: masterUserId } });
  const stored = setting?.daily_score_weights;
  if (!stored) { return { weights: { ...DAILY_SCORE_DEFAULT_WEIGHTS }, source: 'default' }; }
  return { weights: { /* stored values */ }, source: 'crm_setting' };
};

// controller
const { weights, source } = await getDailyScoreWeights(user.id);
return { /* ... */, weights_source: source };
```

## Unique-constraint migrations on legacy data must dedup automatically, not throw

When a migration introduces a UNIQUE index on existing data, it must repair pre-existing duplicates as part of `up()`, not abort. A pre-check that throws turns the migration into a permanent deploy blocker the first time real data violates the constraint — every subsequent CI run fails at the same step, every later migration is skipped, and any feature that depends on those later migrations silently breaks in production. The new code that *prevents* future duplicates does not fix historical rows; the migration must.

The fix-rule: pick a deterministic, collision-free rename (e.g. suffix with the row's PK) for all but one row per duplicate group, do it in a single set-based `UPDATE ... JOIN` (not a Node loop), then add the index. Keep an idempotence guard (skip if the index already exists) and a defensive post-dedup check (throw only if duplicates somehow remain). `down()` should drop the index but **not** try to restore the renamed values — the original duplicates were already a data inconsistency and there is no safe way to know which row should reclaim the original number.

**Bad implementation:**

```js
// migration up()
const [duplicates] = await queryInterface.sequelize.query(`
  SELECT user_id, quotation_number, COUNT(*) AS occurrences
  FROM \`quotations\`
  WHERE quotation_number IS NOT NULL
  GROUP BY user_id, quotation_number
  HAVING COUNT(*) > 1
`);
if (duplicates.length > 0) {
  // Blocks every deploy until someone manually cleans the data.
  throw new Error(`Cannot create unique index: duplicate rows exist. Sample: ${JSON.stringify(duplicates)}`);
}
await queryInterface.addIndex('quotations', { fields: ['user_id', 'quotation_number'], unique: true, name: 'idx_quotation_user_number_unique' });
```

**Good implementation:**

```js
// migration up()
const indexes = new Set((await queryInterface.showIndex('quotations')).map((i) => i.name));
if (indexes.has('idx_quotation_user_number_unique')) { return; } // idempotent

// Single set-based dedup: keep smallest id per group, rename the rest with a
// PK-based suffix (auto-increment id => collision-free).
await queryInterface.sequelize.query(`
  UPDATE \`quotations\` AS q
  JOIN (
    SELECT id, ROW_NUMBER() OVER (PARTITION BY user_id, quotation_number ORDER BY id) AS rn
    FROM \`quotations\`
    WHERE quotation_number IS NOT NULL
  ) AS d ON d.id = q.id
  SET q.quotation_number = CONCAT(q.quotation_number, '-LEGACY-', q.id)
  WHERE d.rn > 1
`);

// Defensive net only — should never fire after the dedup above.
const [stillDup] = await queryInterface.sequelize.query(`
  SELECT user_id, quotation_number, COUNT(*) FROM \`quotations\`
  WHERE quotation_number IS NOT NULL
  GROUP BY user_id, quotation_number HAVING COUNT(*) > 1 LIMIT 5
`);
if (stillDup.length > 0) { throw new Error(`Duplicates still exist after dedup: ${JSON.stringify(stillDup)}`); }

await queryInterface.addIndex('quotations', { fields: ['user_id', 'quotation_number'], unique: true, name: 'idx_quotation_user_number_unique' });
```

## Recompute the upper-bound when Joi has already coerced the date to a Date

Joi's `Joi.date()` coerces the value before the controller runs, so by the time a service receives `to`, it is a `Date` — not a `"YYYY-MM-DD"` string. A check like `typeof to === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(to)` is dead code, and the "extend to end-of-day" branch never fires: a user passing `2025-11-05` ends up with `Op.lte` of `2025-11-05T00:00:00Z` and the whole day is excluded from the window. Detect "midnight UTC" on the parsed `Date` instead, and use an exclusive `Op.lt` of next-day-midnight so the boundary is inclusive of the requested day without any string sniffing.

**Bad implementation:**

```
if (to) {
    const isDateOnly = typeof to === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(to);
    where.occurred_at[Op.lte] = isDateOnly ? new Date(`${to}T23:59:59.999Z`) : new Date(to);
}
```

**good implementation**

```
if (to) {
    const toDate = to instanceof Date ? new Date(to.getTime()) : new Date(to);
    const isMidnight = toDate.getUTCHours() === 0
        && toDate.getUTCMinutes() === 0
        && toDate.getUTCSeconds() === 0
        && toDate.getUTCMilliseconds() === 0;
    if (isMidnight) {
        toDate.setUTCDate(toDate.getUTCDate() + 1);
        where.occurred_at[Op.lt] = toDate;
    } else {
        where.occurred_at[Op.lte] = toDate;
    }
}
```

## Guard against arrays before spreading user-supplied metadata

In JavaScript `typeof [] === 'object'`, so a `extra_metadata && typeof extra_metadata === 'object'` check happily lets `[1,2,3]` through. Spreading an array with `...` produces numeric keys (`{ '0': 1, '1': 2 }`) and silently corrupts the JSON metadata column — and a malicious caller can use this to inject arbitrary integer-keyed entries. Add an explicit `!Array.isArray(extra_metadata)` clause so only plain objects are merged.

**Bad implementation:**

```
metadata: {
    ...(extra_metadata && typeof extra_metadata === 'object' ? extra_metadata : {}),
    attribution_mode,
    commercial_id,
}
```

**good implementation**

```
metadata: {
    ...(extra_metadata && typeof extra_metadata === 'object' && !Array.isArray(extra_metadata)
        ? extra_metadata
        : {}),
    attribution_mode,
    commercial_id,
}
```

## Short-circuit no-op updates before opening the transaction

When a "set X" endpoint is called with the value already in DB, running the bulk `UPDATE` and writing an `*_changed` audit log entry is wasteful and produces a misleading audit trail (a "change" log with `previous_value === new_value`). Detect the no-op at the top of the handler, return the existing audit metadata (timestamp + author of the last real change), and never open the transaction. Same rule applies to the audit-log writer itself: `recordAttributionModeChanged` should early-return when `previous_value === new_value` so any caller is protected.

**Bad implementation:**

```
const result = await sequelize.transaction(async (transaction) => {
    await models[CUSTOMER].update({ attribution_mode: attributionMode }, { where, transaction });
    let occurredAt = null;
    let updatedBy = null;
    if (previousValue !== attributionMode) {
        const log = await recordProspectActivityLog({ ... });
        occurredAt = log?.occurred_at;
        updatedBy = actor.id;
    } else {
        const existing = await getLatestAttributionModeChangeLog(rootOwnerId);
        occurredAt = existing?.occurred_at || null;
        updatedBy = existing?.author_user_id || null;
    }
    return { attribution_mode: attributionMode, updated_at: occurredAt, updated_by: updatedBy };
});
```

**good implementation**

```
if (previousValue === attributionMode) {
    const existing = await getLatestAttributionModeChangeLog(rootOwnerId);
    return {
        attribution_mode: attributionMode,
        updated_at: existing?.occurred_at || null,
        updated_by: existing?.author_user_id || null,
    };
}

const result = await sequelize.transaction(async (transaction) => {
    await models[CUSTOMER].update({ attribution_mode: attributionMode }, { where, transaction });
    const log = await recordProspectActivityLog({ ... });
    return { attribution_mode: attributionMode, updated_at: log?.occurred_at || null, updated_by: actor.id };
});
```

## Apply team-level defaults on every insert path, not just the single-row one

When a per-team setting (e.g. `attribution_mode`) is resolved in `createCustomer` but the bulk `importCustomer` path calls `insertMultiRow` directly with the raw input, imported rows skip the team default and land with the column default — silently desynchronising imported customers from manually created ones. Resolve the team setting once at the top of the import handler and inject it into every row in the batch map, so single and bulk insert paths produce identical state.

**Bad implementation:**

```
// createCustomer applies team default
const teamAttributionMode = (await resolveTeamAttributionMode(rootOwnerId, teamUserIds)).mode;
await models[CUSTOMER].create({ ...customerFields, attribution_mode: teamAttributionMode });

// importCustomer forgot it
const createdCustomers = await insertMultiRow(
    CUSTOMER,
    batchWithAddresses.map((item) => item.customerFields), // attribution_mode missing
    transaction,
);
```

**good implementation**

```
let teamAttributionMode = ATTRIBUTION_MODE.MANUAL;
try {
    const rootOwnerId = getRootOwnerId(user);
    const teamUserIds = await getTeamUserIds(rootOwnerId);
    teamAttributionMode = (await resolveTeamAttributionMode(rootOwnerId, teamUserIds)).mode;
} catch (err) {
    console.error('resolveTeamAttributionMode failed in importCustomer:', err);
}

const createdCustomers = await insertMultiRow(
    CUSTOMER,
    batchWithAddresses.map((item) => ({ ...item.customerFields, attribution_mode: teamAttributionMode })),
    transaction,
    { returning: true },
);
```

## Per-row transactions for batch cleanup jobs

When cleaning up many rows in a cron/background job, wrapping the entire batch in a single transaction means one bad row rolls back all the others' work. Open a fresh transaction per row, commit it on success, roll back on failure, and keep counting successful releases. Move the initial `findAll` outside the loop so a read failure does not blow up the whole job.

**Bad implementation:**

```
const cleanupExpiredLocks = async () => {
    const t = await sequelize.transaction();
    try {
        const rows = await Lock().findAll({ where: { released_at: null, expires_at: { [Op.lt]: new Date() } }, transaction: t });
        for (const row of rows) {
            row.released_at = new Date();
            await row.save({ transaction: t });
            await recordLockActivity({ action_type: ACTION_TYPE.LOCK_EXPIRED, lockRow: row.get({ plain: true }), transaction: t });
        }
        await t.commit();
        return rows.length;
    } catch (err) {
        await t.rollback();
        return 0;
    }
};
```

**good implementation**

```
const cleanupExpiredLocks = async () => {
    let rows;
    try {
        rows = await Lock().findAll({ where: { released_at: null, expires_at: { [Op.lt]: new Date() } } });
    } catch (err) {
        console.error('cleanupExpiredLocks: failed to load expired locks', err);
        return 0;
    }

    let releasedCount = 0;
    for (const row of rows) {
        const t = await sequelize.transaction();
        try {
            row.released_at = new Date();
            await row.save({ transaction: t });
            await recordLockActivity({ action_type: ACTION_TYPE.LOCK_EXPIRED, lockRow: row.get({ plain: true }), transaction: t });
            await t.commit();
            releasedCount += 1;
        } catch (err) {
            try { await t.rollback(); } catch (_) {}
            console.error('cleanupExpiredLocks: failed for lock', row.id, err);
        }
    }
    return releasedCount;
};
```

## Treat expired locks as inactive in every read path

A lock has both `released_at IS NULL` and `expires_at > NOW()`. Cleanup jobs run on a schedule, so between runs the DB holds rows that are technically "not released" but already expired. Any query that surfaces "the user's active lock" must include the `expires_at > NOW()` predicate; otherwise stale rows leak into business logic (queue display, ownership check, conflict detection) and the cleanup job becomes a correctness dependency instead of a janitor.

**Bad implementation:**

```
const getActiveLockBySession = async (sessionId, transaction) =>
    Lock().findOne({
        where: { session_id: sessionId, released_at: null },
        transaction,
    });

const activeLock = await models[BUSINESS_OPPORTUNITY_LOCK].findOne({
    where: { user_id: authUserId, released_at: null },
});
```

**good implementation**

```
const getActiveLockBySession = async (sessionId, transaction) =>
    Lock().findOne({
        where: {
            session_id: sessionId,
            released_at: null,
            expires_at: { [Op.gt]: new Date() },
        },
        transaction,
    });

const activeLock = await models[BUSINESS_OPPORTUNITY_LOCK].findOne({
    where: {
        user_id: authUserId,
        released_at: null,
        expires_at: { [Op.gt]: new Date() },
    },
});
```

## Verify lock ownership at the action boundary, not just at acquisition

Acquiring a lock to "next BO" and creating the call are two separate HTTP requests. Without re-checking at call creation, a user whose lock expired (or was released by suspension/cleanup) can still post a call against the BO and bypass the AUTO-mode exclusivity guarantee. Validate ownership with a fresh DB read inside the action handler before mutating state.

**Bad implementation:**

```
const createSessionCall = async (authUserId, body, lang) => {
    // ... fetch customer / business_opportunity ...
    validateCustomerRelations(customer, business_opportunity_id, contact_id, lang);
    // proceed to create the call regardless of lock state
};
```

**good implementation**

```
const createSessionCall = async (authUserId, body, lang) => {
    // ... fetch customer / business_opportunity ...
    validateCustomerRelations(customer, business_opportunity_id, contact_id, lang);

    if (customer.attribution_mode === ATTRIBUTION_MODE.AUTO) {
        const heldLock = await models[BUSINESS_OPPORTUNITY_LOCK].findOne({
            where: {
                business_opportunity_id,
                session_id: session.id,
                user_id: authUserId,
                released_at: null,
                expires_at: { [Op.gt]: new Date() },
            },
        });
        if (!heldLock) {
            throw createError.Forbidden(sessionCallMessage(lang).BUSINESS_OPPORTUNITY_NOT_FOUND);
        }
    }
    // ...create the call
};
```

## Release held resources before terminal status transitions

Lifecycle transitions like `suspendSessions` (cron-driven) flip a session to SUSPENDED but used to leave its `business_opportunity_lock` rows behind, so a BO stayed locked to a user who could no longer act on it. Any state machine that owns external resources must release them in the same transaction as the status change — both for normal lifecycle paths (pause, end) and for system-driven ones (suspend, expire).

**Bad implementation:**

```
const suspendSessions = async () => {
    // ... pick eligible sessions ...
    const [affectedRows] = await models[SESSION].update(
        { status: SESSION_STATUS.SUSPENDED, suspended_at: moment.utc().toDate() },
        { where: { id: session.id, status: { [Op.in]: [ACTIVE, PAUSED] } }, transaction: t },
    );
    // locks left dangling
};
```

**good implementation**

```
const suspendSessions = async () => {
    // ... pick eligible sessions ...
    await lockService.releaseLock({
        where: { session_id: session.id },
        reason: 'session_suspended',
        userId: null,
        transaction: t,
    });

    const [affectedRows] = await models[SESSION].update(
        { status: SESSION_STATUS.SUSPENDED, suspended_at: moment.utc().toDate() },
        { where: { id: session.id, status: { [Op.in]: [ACTIVE, PAUSED] } }, transaction: t },
    );
};
```

## Always go through the service helper to release a lock — never mutate the row directly

`lockService.releaseLock` does more than set `released_at`: it also writes an audit row (`recordLockActivity`) with the release reason and actor. Manually doing `lock.released_at = new Date(); await lock.save()` skips the audit trail, so a release that happened during a retry/inaccessibility branch becomes invisible in the activity log.

**Bad implementation:**

```
const payload = await getBoPayload(ownerUserId, candidateId, t);
if (!payload) {
    lock.released_at = new Date();
    await lock.save({ transaction: t });
    continue;
}
```

**good implementation**

```
const payload = await getBoPayload(ownerUserId, candidateId, t);
if (!payload) {
    await lockService.releaseLock({
        where: { id: lock.id },
        reason: 'bo_inaccessible',
        userId: authUserId,
        transaction: t,
    });
    continue;
}
```

## Hoist tuning constants out of the body of retry/loop logic

A bare `if (attempts >= 5) break;` mid-function hides a tuning knob in code-review territory: nobody finds it when production wants to bump it, and grep across modules for "max attempts" misses it. Promote the bound to a named constant on the same config namespace as the rest of the feature (e.g. `BUSINESS_OPPORTUNITY.LOCK.ACQUIRE_MAX_ATTEMPTS`) so it lives next to the lock TTL and other knobs.

**Bad implementation:**

```
let attempts = 0;
for (const candidateId of orderedEligible) {
    if (attempts >= 5) { break; }
    attempts += 1;
    // try to acquire lock on candidateId ...
}
```

**good implementation**

```
let attempts = 0;
for (const candidateId of orderedEligible) {
    if (attempts >= appConst.BUSINESS_OPPORTUNITY.LOCK.ACQUIRE_MAX_ATTEMPTS) { break; }
    attempts += 1;
    // try to acquire lock on candidateId ...
}
```

## Tighten Joi validators on identifier fields with `.positive()`

`Joi.number().integer().required()` accepts `0` and negative integers, which then hit a `findByPk` / `WHERE id = ?` query that returns nothing and produces a confusing 404 (or worse, matches a soft-deleted row in some schemas). For DB identifiers always chain `.positive()` so the validator rejects the bad input at the boundary with a clear "must be a positive integer" message.

**Bad implementation:**

```
module.exports.schemaReleaseCurrentLock = {
    body: Joi.object({
        business_opportunity_id: Joi.number().integer().required(),
    }),
};
```

**good implementation**

```
module.exports.schemaReleaseCurrentLock = {
    body: Joi.object({
        business_opportunity_id: Joi.number().integer().positive().required(),
    }),
};
```

## Never silently swallow errors in `catch` — log first, then fall back

`} catch { return res.json({ count: 0, rows: [] }); }` makes a real failure (DB outage, mis-includes, schema drift) indistinguishable from "no data". The fallback is fine for UX, but log the error with enough context (route + relevant id) before returning the empty payload, so the issue surfaces in logs/alerting.

**Bad implementation:**

```
try {
    const payload = await getBoPayload(authUserId, activeLock.business_opportunity_id);
    return res.json({ count: 1, rows: [{ ...payload, lock_expires_at: activeLock.expires_at }] });
} catch {
    return res.json({ count: 0, rows: [] });
}
```

**good implementation**

```
try {
    const payload = await getBoPayload(authUserId, activeLock.business_opportunity_id);
    return res.json({ count: 1, rows: [{ ...payload, lock_expires_at: activeLock.expires_at }] });
} catch (err) {
    console.error('[GET /current/queue] failed to load locked BO payload', activeLock.business_opportunity_id, err);
    return res.json({ count: 0, rows: [] });
}
```

## Pass the transaction to every read inside a beforeCreate / beforeUpdate hook

When a service hook runs inside a Sequelize transaction (e.g. `beforeCreate`, `beforeUpdate`), every read it performs — duplicate checks, ownership lookups, anything used to validate the write — must receive the same `transaction` option. Otherwise the read uses the default snapshot/connection and cannot see in-flight inserts/updates from the same transaction, so duplicate-detection silently passes when concurrent requests collide and ownership checks may read stale rows.

**Bad implementation:**

```js
beforeCreate: async (user, data, lang, transaction, req) => {
    if (data.user_id) {
        // No transaction — reads from outside the in-flight tx.
        const targetUser = await models[USER].findByPk(data.user_id);
        if (!targetUser || targetUser.owner_id !== req.authUserId) { throw createError.Forbidden(...); }
    }
    // No transaction — duplicate check is racy, two concurrent creates both see "no duplicate" and both succeed.
    const duplicate = await models[CONFIG].findOne({
        where: { label: data.label, manager_id: data.manager_id, user_id: data.user_id || { [Op.is]: null } },
    });
    if (duplicate) { throw createError.BadRequest(...); }
}
```

**good implementation**

```js
beforeCreate: async (user, data, lang, transaction, req) => {
    if (data.user_id) {
        const targetUser = await models[USER].findByPk(data.user_id, { transaction });
        if (!targetUser || targetUser.owner_id !== req.authUserId) { throw createError.Forbidden(...); }
    }
    const duplicate = await models[CONFIG].findOne({
        where: { label: data.label, manager_id: data.manager_id, user_id: data.user_id || { [Op.is]: null } },
        transaction,
    });
    if (duplicate) { throw createError.BadRequest(...); }
}
```

Note that DB-level uniqueness (UNIQUE indexes, ideally on COALESCE-normalized columns when scope keys are nullable) remains the real guard — application-level checks just give nicer error messages. But if you keep the application check, run it inside the transaction.

## Escape `%` and `_` when interpolating user input into a LIKE pattern

When a search query is wrapped in `%...%` for a `LIKE` filter, the user-supplied string is interpreted as a pattern. A user typing `100%` or `foo_bar` will match unexpected rows; a user typing `%%%%%%%%` can also force the DB into expensive scans. Escape `%`, `_`, and `\` before injecting the value into the pattern.

**Bad implementation:**

```js
if (q) {
    where.label = { [Op.like]: `%${q}%` };
}
```

**good implementation**

```js
if (q) {
    const escapedQ = q.replace(/[\\%_]/g, '\\$&');
    where.label = { [Op.like]: `%${escapedQ}%` };
}
```

The order in the regex character class matters — `\\` (backslash) must come first so it doesn't double-escape the other characters. Sequelize forwards LIKE patterns verbatim to the DB, so this escaping is mandatory whenever the value comes from a request payload.

## Use `UUIDV4` for new UUID primary keys

UUID v1 embeds the host's MAC address and a high-resolution timestamp. Using it as a public primary key leaks infrastructure metadata and the row's creation moment, and ids become predictable enough to enable enumeration. v4 is purely random — prefer it everywhere unless you specifically need time-ordering (and even then, prefer ULID/UUIDv7 over v1).

**Bad implementation:**

```js
id: {
    type: DataTypes.UUID,
    defaultValue: DataTypes.UUIDV1,
    primaryKey: true,
},
```

**good implementation**

```js
id: {
    type: DataTypes.UUID,
    defaultValue: DataTypes.UUIDV4,
    primaryKey: true,
},
```

Apply this to BOTH the migration (`createTable`) and the Sequelize model — they must agree, otherwise rows inserted by the model get a different default than rows created via raw SQL.

## Cap unbounded array inputs in Joi validators

Any payload field that drives a loop, a bulk DB write, or a `WHERE id IN (...)` lookup must declare an explicit `.max()` in its Joi schema. Without it, a single request can pin an event-loop worker, blow out a transaction, or trigger pathological query plans. Pick a bound that matches the real product cap (here: 100 BOs at once) — never leave it open-ended.

**Bad implementation:**

```js
const schema_bulkAssign = {
    body: Joi.object({
        assigned_user_id: Joi.string().uuid().required(),
        business_opportunity_ids: Joi.array().items(Joi.number().integer().positive()).min(1).required(),
    }),
};
```

**good implementation**

```js
const schema_bulkAssign = {
    body: Joi.object({
        assigned_user_id: Joi.string().uuid().required(),
        business_opportunity_ids: Joi.array().items(Joi.number().integer().positive()).min(1).max(100).required(),
    }),
};
```

The `.max()` belongs at the validator layer, not deep in the service — fail fast at the boundary so the rest of the pipeline (transactions, activity-log writes, etc.) never sees an oversized payload.

## Reject self-targeting in manager/owner authorization checks

When an endpoint lets user A act on user B (assign work, change role, impersonate), the "is A the manager of B" check almost always also needs an explicit "A ≠ B" guard. Otherwise a manager can quietly assign work to themselves, escalate, or break business rules that assume the two roles are distinct. Add the guard at the very top of the authz helper so every caller inherits it.

**Bad implementation:**

```js
const ensureManagerOf = async (authUserId, targetUserId, transaction) => {
    const target = await models[USER].findOne({
        where: { id: targetUserId },
        attributes: ['id', 'owner_id'],
        transaction,
    });
    if (!target || target.owner_id !== authUserId) {
        throw createError.Forbidden();
    }
};
```

**good implementation**

```js
const ensureManagerOf = async (authUserId, targetUserId, transaction) => {
    if (authUserId === targetUserId) {
        throw createError.Forbidden('Cannot assign to yourself');
    }
    const target = await models[USER].findOne({
        where: { id: targetUserId },
        attributes: ['id', 'owner_id'],
        transaction,
    });
    if (!target || target.owner_id !== authUserId) {
        throw createError.Forbidden();
    }
};
```

## Reload Sequelize instances INSIDE the transaction, before commit

A common shape is "update inside a transaction, commit, then `instance.reload()` so the caller gets the fresh row". The reload after commit runs on a fresh connection without the transaction, so it can race against concurrent writers and return data that diverges from what was just committed. Reload before the commit, passing the same transaction — you read your own writes, atomically.

**Bad implementation:**

```js
await assignment.update(patch, { transaction: t });
// ...other writes inside t...
await t.commit();
await assignment.reload(); // outside the transaction
return assignment.get({ plain: true });
```

**good implementation**

```js
await assignment.update(patch, { transaction: t });
// ...other writes inside t...
await assignment.reload({ transaction: t });
await t.commit();
return assignment.get({ plain: true });
```

The order matters: reload first (still in the transaction), then commit. After commit the transaction is gone, so passing it would also be wrong — the rule is "reload while you still hold `t`".

## When replacing a stored column with a virtual computed field, audit EVERY call-site

Dropping a real column (e.g. `products.picture`) in favour of a value computed from an association (`images.is_main → picture`) only works if every place that reads the column is updated to (a) eager-load the association in its `find()` and (b) recompute the field afterwards. Miss one service and the response silently returns `undefined` for the field — type-checks pass, the migration passes, but the front-end breaks. Grep for the column name across the whole repo before merging, including secondary services like exports, PDFs, and payment flows.

**Bad implementation:**

```js
// service A — updated
const products = await find(PRODUCT, { id }, [{ model: models[PRODUCT_IMAGE], as: 'images', ... }]);
return products.map((p) => ({ ...p, picture: getMainPictureUrl(p.images) }));

// service B (multi-party-payment) — forgotten, still reads the dropped column
let products = await find(PRODUCT, { id: product_ids });
products = JSON.parse(JSON.stringify(products));
// products[i].picture is undefined forever
```

**good implementation**

```js
// every call-site goes through the same shape
const productsRaw = await find(
    PRODUCT,
    { id: product_ids },
    [{ model: models[PRODUCT_IMAGE], as: 'images', required: false, attributes: ['id', 'url', 'is_main', 'position'] }]
);
const products = JSON.parse(JSON.stringify(productsRaw)).map((p) => ({
    ...p,
    picture: getMainPictureUrl(p.images),
}));
```

Centralize the recomputation in a single helper (`getMainPictureUrl`) so every call-site stays in sync, and add a grep step ("`\.picture`" / "`PRODUCT,`") to your pre-merge checklist when removing a column.

## Re-resolve "previous value" inside the transaction with a row lock to close TOCTOU races

When a mutation branches on a current state read before the transaction (e.g. "if previous mode is AUTO, release locks"), two concurrent requests can both read the same `previousValue` outside the transaction and then both apply mutually-exclusive side effects. The fix is to (1) `SELECT ... FOR UPDATE` the rows that decide the branch at the very start of the transaction, (2) re-resolve the previous value *using the same transaction*, and (3) branch on that transactional value — not the pre-transaction one. Helpers used to resolve the value must accept and forward the `transaction` so the read happens inside the lock. Also tighten validators to only the values that are actually switchable; rely on Joi to reject the rest instead of defending in the service.

**Bad implementation:**

```js
// previousValue read OUTSIDE the transaction → racy
const { mode: previousValue } = await resolveTeamAttributionMode(rootOwnerId, teamUserIds);

const result = await sequelize.transaction(async (transaction) => {
    await models[CUSTOMER].update(
        { attribution_mode: attributionMode },
        { where: { user_id: { [Op.in]: teamUserIds } }, transaction }
    );

    if (previousValue === ATTRIBUTION_MODE.AUTO && attributionMode === ATTRIBUTION_MODE.MANAGER) {
        await releaseLocks(teamUserIds, transaction);   // both concurrent calls may enter
    }
    if (previousValue === ATTRIBUTION_MODE.MANAGER && attributionMode === ATTRIBUTION_MODE.AUTO) {
        await processAssignments(teamUserIds, transaction); // …or this branch
    }
});

// validator allows every mode, even non-switchable ones (MANUAL, etc.)
const schema = {
    body: Joi.object({
        attribution_mode: Joi.string().valid(...ATTRIBUTION_MODES).required(),
    }),
};
```

**good implementation**

```js
const result = await sequelize.transaction(async (transaction) => {
    // 1. Lock the rows whose state drives the branch
    await models[CUSTOMER].findAll({
        where: { user_id: { [Op.in]: teamUserIds } },
        attributes: ['id'],
        lock: transaction.LOCK.UPDATE,
        transaction,
    });

    // 2. Re-resolve previousValue inside the transaction
    const { mode: txPreviousValue } = await resolveTeamAttributionMode(rootOwnerId, teamUserIds, transaction);

    // 3. Idempotency: a concurrent winner may have already applied the switch
    if (txPreviousValue === attributionMode) {
        const existing = await getLatestAttributionModeChangeLog(rootOwnerId, transaction);
        return { attribution_mode: attributionMode, updated_at: existing?.occurred_at || null };
    }

    await models[CUSTOMER].update(
        { attribution_mode: attributionMode },
        { where: { user_id: { [Op.in]: teamUserIds } }, transaction }
    );

    if (txPreviousValue === ATTRIBUTION_MODE.AUTO && attributionMode === ATTRIBUTION_MODE.MANAGER) {
        await releaseLocks(teamUserIds, transaction);
    }
    if (txPreviousValue === ATTRIBUTION_MODE.MANAGER && attributionMode === ATTRIBUTION_MODE.AUTO) {
        await processAssignments(teamUserIds, transaction);
    }
});

// Helpers thread the transaction so reads happen under the same lock
const getLatestAttributionModeChangeLog = async (rootOwnerId, transaction = null) =>
    findOne(TABLE.PROSPECT_ACTIVITY_LOG, where, null, { order: [['occurred_at', 'DESC']], raw: true, transaction });

const resolveTeamAttributionMode = async (rootOwnerId, teamUserIds, transaction = null) => {
    const lastLog = await getLatestAttributionModeChangeLog(rootOwnerId, transaction);
    // …
};

// Validator restricts to switchable modes only
const SWITCHABLE_ATTRIBUTION_MODES = [ATTRIBUTION_MODE.AUTO, ATTRIBUTION_MODE.MANAGER];
const schema = {
    body: Joi.object({
        attribution_mode: Joi.string().valid(...SWITCHABLE_ATTRIBUTION_MODES).required(),
    }),
};
```

Rule of thumb: any value that is both *read to decide a branch* and *written by the same operation* must be re-read inside the transaction with `LOCK.UPDATE` on the deciding rows. Pre-transaction reads are fine for early-exit / preview, but never for the authoritative branch.

## Apply shared filters consistently across every branch of a query helper

When a helper builds a query with multiple branches (e.g., short-circuit on a fully qualified key vs. a fallback predicate), every branch must apply the same cross-cutting filters — especially status/soft-delete exclusions. An early-return branch that omits the shared filter will surface stale or terminal-state rows that the rest of the helper deliberately ignores, which silently breaks dedup, listing, and policy logic.

**Bad implementation:**

```js
const findExistingConnection = async (sent_from, sent_to, job_id, cv_id, options = null) => {
    if (job_id && cv_id) {
        // Early return forgets the NON_BLOCKING_CONNECTION_STATUSES filter,
        // so a CANCELED / DISCONNECTED / DEACTIVATED row will block a new create.
        return findOne(CONNECTION, { job_id, cv_id }, null, options || undefined);
    }
    const where = {
        [Op.or]: [
            { sent_from, sent_to },
            { sent_from: sent_to, sent_to: sent_from },
        ],
        status: { [Op.notIn]: NON_BLOCKING_CONNECTION_STATUSES },
    };
    if (job_id) where.job_id = job_id;
    if (cv_id) where.cv_id = cv_id;
    return findOne(CONNECTION, where, null, options || undefined);
};
```

**good implementation**

```js
const findExistingConnection = async (sent_from, sent_to, job_id, cv_id, options = null) => {
    if (job_id && cv_id) {
        return findOne(
            CONNECTION,
            {
                job_id,
                cv_id,
                status: { [Op.notIn]: NON_BLOCKING_CONNECTION_STATUSES },
            },
            null,
            options || undefined
        );
    }
    const where = {
        [Op.or]: [
            { sent_from, sent_to },
            { sent_from: sent_to, sent_to: sent_from },
        ],
        status: { [Op.notIn]: NON_BLOCKING_CONNECTION_STATUSES },
    };
    if (job_id) where.job_id = job_id;
    if (cv_id) where.cv_id = cv_id;
    return findOne(CONNECTION, where, null, options || undefined);
};
```

Rule of thumb: cross-cutting predicates (status exclusions, tenant scoping, soft-delete `deleted_at IS NULL`) must be factored into a shared `where` builder or applied in every branch. If you need an early return for a specialized lookup, copy the filter — or better, restructure so there is a single `findOne` call with a composed `where`.

## Scope the transaction try/catch to DB work only — do not rollback after commit

When a service opens a Sequelize transaction with `sequelize.transaction()`, the `try` block must contain only the DB operations that participate in the transaction. Any post-commit work (re-fetching with includes, serialization, response shaping) must live **outside** the `try/catch`. Otherwise an error thrown after `t.commit()` falls into the `catch` and triggers `t.rollback()` on an already-committed transaction — which throws a confusing secondary error and masks the real one.

**Bad implementation:**

```js
const t = await sequelize.transaction();
try {
    const product = await create(PRODUCT, { ...productData, user_id: user.id }, t);
    await cascadeCreateImages({ productId: product.id, transaction: t });
    await t.commit();

    // Post-commit work still inside the try — any failure here calls rollback() on a committed tx
    if (includeRelations) {
        return getProductById(user, product.id, lang, { include: 'documents,suppliers,custom_values' });
    }
    return JSON.parse(JSON.stringify(product));
} catch (e) {
    await t.rollback();
    throw e;
}
```

**good implementation**

```js
const t = await sequelize.transaction();
let product;
try {
    product = await create(PRODUCT, { ...productData, user_id: user.id }, t);
    await cascadeCreateImages({ productId: product.id, transaction: t });
    await t.commit();
} catch (e) {
    await t.rollback();
    throw e;
}

// Post-commit work is outside the try: failures here cannot trigger rollback on a committed tx
if (includeRelations) {
    return getProductById(user, product.id, lang, { include: 'documents,suppliers,custom_values' });
}
return JSON.parse(JSON.stringify(product));
```

Rule of thumb: `t.commit()` is the last statement inside the `try`. Anything that runs after a successful commit (reloads, response shaping, side effects you don't want rolled back anyway) belongs after the `try/catch` block. Bonus: when accepting user-controlled arrays for cascade inserts (`images`, `documents`, `suppliers`, `custom_field_values`), always cap them with Joi `.max(N)` and tighten leaf validation (`Joi.string().uri().max(2048)` for URLs, typed alternatives for free-form `value` fields) to prevent oversized payloads from blowing up the transaction.

## Don't apply default-builders on UPDATE/PATCH paths

Helpers that set field defaults (`applyAfnorDefaults`, fallback fillers, etc.) belong only on create. On a PATCH/PUT, a missing field means "leave it alone", not "use the default". Calling a defaults helper inside `updateQuotation`/`updateQuotationV2` silently overwrote existing `validity_days`, `payment_terms` and `signature_block` whenever the client sent a partial update.

**Bad implementation:**

```js
const updateQuotation = async (user, id, body, lang) => {
    body.customer = quotation.customer || null;
    user = await getUserDetail(user);
    applyAfnorDefaults(body, user, body.customer); // ❌ stomps existing values on partial update
    if (!body.products) body.products = quotation.products;
    ...
};
```

**good implementation**

```js
const updateQuotation = async (user, id, body, lang) => {
    body.customer = quotation.customer || null;
    user = await getUserDetail(user);
    // ✅ no applyAfnorDefaults — partial updates must not re-default missing fields
    if (!body.products) body.products = quotation.products;
    ...
};
```

Rule of thumb: a `applyXxxDefaults(body, …)` helper is a *create*-time concern. If you ever need to set a value on update, do it explicitly for that one field, never via a bulk-defaults helper.

## Run dependent validation AFTER applying defaults

If validation reads a field that the defaults helper fills in (`expired_date` derived from `validity_days`), the validation must run *after* the helper, not before. Otherwise legitimate inputs (a SENT quote with no explicit `expired_date`) are rejected because the value hadn't been materialised yet.

**Bad implementation:**

```js
// ❌ validation reads raw body — expired_date is undefined for SENT quotes
if (status === STATUS.SENT || status === STATUS.VALIDATED) {
    if (!created_on || !expired_date || moment(created_on) > moment(expired_date) || moment() > moment(expired_date)) {
        throw createError.BadRequest(...);
    }
}
applyAfnorDefaults(body, user, body.customer);
```

**good implementation**

```js
applyAfnorDefaults(body, user, body.customer);
// ✅ validation reads the body AFTER defaults populated expired_date from validity_days
if (status === STATUS.SENT || status === STATUS.VALIDATED) {
    if (!body.created_on || !body.expired_date ||
        moment(body.created_on) > moment(body.expired_date) ||
        moment() > moment(body.expired_date)) {
        throw createError.BadRequest(...);
    }
}
```

Note: reading `expired_date` from a destructured const captured before the helper ran is the most common form of this bug — always re-read `body.expired_date` after a helper has mutated `body`.

## Guard JSON parsing in Sequelize getters with isJson

A model getter that does `JSON.parse(this.getDataValue(col))` will crash every read of that row if the column ever contains a non-JSON string (legacy data, partial writes, a manually edited row). Always probe with `isJson` first and return `null` on bad data — never let the parser surface as a 500 to the caller.

**Bad implementation:**

```js
get: function () {
    if (this.getDataValue('quotation_defaults')) {
        return JSON.parse(this.getDataValue('quotation_defaults')); // ❌ throws on malformed JSON
    }
},
```

**good implementation**

```js
const { isJson } = require('../../../helpers/utility.helper');
...
get: function () {
    const raw = this.getDataValue('quotation_defaults');
    if (raw && isJson(raw)) return JSON.parse(raw);
    return null; // ✅ never crash on malformed payload
},
```

Applies to every JSON-stored-as-text column (`quotation_defaults`, `btp_data`, `payment_terms`, `external_data`, etc.).

## Mutually-exclusive Joi fields use .oxor(), never hand-rolled checks

When two fields cannot both be set (`deposit_amount` vs `deposit_percent`), express it in Joi with `.oxor()` rather than checking in the service layer. The schema-side check fails fast with a clear path, and you don't risk forgetting it in a second route.

**Bad implementation:**

```js
const paymentTermsSchema = Joi.object({
    deposit_amount: Joi.number().min(0).allow(null).optional(),
    deposit_percent: Joi.number().min(0).max(100).allow(null).optional(),
    ...
}).allow(null).optional();

// service layer
if (body.payment_terms?.deposit_amount && body.payment_terms?.deposit_percent) {
    throw createError.BadRequest('...'); // ❌ duplicated across createV1/createV2/update
}
```

**good implementation**

```js
const paymentTermsSchema = Joi.object({
    deposit_amount: Joi.number().min(0).allow(null).optional(),
    deposit_percent: Joi.number().min(0).max(100).allow(null).optional(),
    ...
})
    .oxor('deposit_amount', 'deposit_percent') // ✅ schema enforces mutual exclusion
    .allow(null)
    .optional();
```

Use `.xor()` when exactly one is required, `.oxor()` when at most one is allowed.

## Asymmetric status enums: server-derived statuses go in list filters, not in update payloads

A status that is only ever set by a cron / server side-effect (here, `EXPIRED`) must be excluded from the update validator (clients must not be able to manually flip a quote to `EXPIRED`) but kept in the list-filter validator (clients legitimately want to query expired records).

**Bad implementation:**

```js
const schema_updateQuotation = {
    body: Joi.object({
        // ❌ EXPIRED is server-derived; allowing it lets clients bypass the cron
        status: Joi.number().integer().valid(DRAFT, SENT, ON_PROCESS, REFUSED, VALIDATED, EXPIRED).optional(),
        ...
    }),
};

const schema_listQuotation = {
    query: Joi.object({
        // ❌ symmetric with update, so list silently filters EXPIRED out
        status: Joi.number().integer().valid(DRAFT, SENT, ON_PROCESS, REFUSED, VALIDATED).optional(),
        ...
    }),
};
```

**good implementation**

```js
const schema_updateQuotation = {
    body: Joi.object({
        // ✅ no EXPIRED — only the cron may transition into it
        status: Joi.number().integer().valid(DRAFT, SENT, ON_PROCESS, REFUSED, VALIDATED).optional(),
        ...
    }),
};

const schema_listQuotation = {
    query: Joi.object({
        // ✅ EXPIRED listed — clients can filter for expired quotes
        status: Joi.alternatives(
            Joi.number().integer().valid(DRAFT, SENT, ON_PROCESS, REFUSED, VALIDATED, EXPIRED).optional(),
            Joi.array().items(Joi.number().integer().valid(DRAFT, SENT, ON_PROCESS, REFUSED, VALIDATED, EXPIRED).optional()).optional()
        ),
        ...
    }),
};
```

Rule of thumb: for each non-client-settable status, audit every validator separately — read vs. write are not symmetric.

## Add a composite index for the cron's WHERE clause

A daily cron that runs `WHERE status IN (...) AND expired_date < NOW()` against a growing table will full-scan unless you add a composite index on `(status, expired_date)`. Add it in the same migration that introduces the column — never rely on the existing single-column index on `status` (low selectivity once you have many SENT quotes).

**Bad implementation:**

```js
// migration adds expired_date column, no index
await queryInterface.addColumn(TABLE, 'expired_date', { type: DataTypes.DATE, allowNull: true });
// cron query: SELECT ... WHERE status IN (1,2,3) AND expired_date < NOW()  ❌ full scan
```

**good implementation**

```js
await queryInterface.addColumn(TABLE, 'expired_date', { type: DataTypes.DATE, allowNull: true });
await queryInterface.addIndex(TABLE, ['status', 'expired_date'], {
    name: `${TABLE}_status_expired_date_idx`, // ✅ supports the daily expiry cron
});
```

General rule: any column that becomes part of a recurring background job's predicate gets its index added in the same migration. Don't wait for the first slow-query alert.

## Never double-reserve a sequence number

Atomic sequence reservers (e.g. `createQuotationWithUniqueNumber`, AFNOR/Devis no-gap counters) already burn one slot per call. Calling `getNumberQuotation(user)` beforehand and then calling the atomic creator means **every create consumes two sequence slots**, and every `PREVIEW_DRAFT` burns a real slot it will never use — both break the AFNOR "no gap" requirement and leak numbers to auditors.

**Bad implementation:**

```js
await applyQuoteCompliance({ user, customer: body.customer, body });
body.quotation_number = await getNumberQuotation(user); // ❌ reserves a seq slot
// ...
if (action === ACTION.PREVIEW_DRAFT) {
    // ❌ preview burns the real number for a throwaway PDF
    await generateAndUploadPdfQuotation({ ...dataCreateQuotation, user }, 'fr');
}
// ...
await createQuotationWithUniqueNumber(dataCreateQuotation); // reserves AGAIN
```

**good implementation**

```js
await applyQuoteCompliance({ user, customer: body.customer, body });
// ✅ no pre-reservation — the atomic creator owns the sequence
if (action === ACTION.PREVIEW_DRAFT) {
    dataCreateQuotation.quotation_number = '[PREVIEW]'; // ✅ placeholder, no seq burned
    await generateAndUploadPdfQuotation({ ...dataCreateQuotation, user }, 'fr');
}
// ...
await createQuotationWithUniqueNumber(dataCreateQuotation); // ✅ single reservation
```

Rule of thumb: any "atomic reserver" helper is the **only** place a sequence is consumed. Previews, drafts, and dry-runs get a hardcoded placeholder.

## Use `??` (not `||`) when zero is a legitimate value

`||` treats `0`, `''`, and `false` as falsy and falls through to the next operand. For monetary fields (`total_paid`, `total_ttc`, `total_remains`), discounts, and counters, `0` is a real value — using `||` silently rewrites a legitimate zero into the previous DB value, which can clobber `total_remains` to wrong amounts and ship invoices with incorrect "amount due".

**Bad implementation:**

```js
// body.total_paid = 0 (client zeroed the paid amount)
body.total_remains =
    (body.total_ttc || quotation.total_ttc || 0) - (body.total_paid || quotation.total_paid || 0);
// ❌ 0 falls through to quotation.total_paid → total_remains computed against stale paid value
```

**good implementation**

```js
body.total_remains =
    (body.total_ttc ?? quotation.total_ttc ?? 0) - (body.total_paid ?? quotation.total_paid ?? 0);
// ✅ only null/undefined fall through; explicit 0 from the client is respected
```

Rule of thumb: for any numeric, boolean, or money field where `0`/`false`/`''` is meaningful, default with `??`. Reserve `||` for "string is empty OR missing" cases where you actually want both treated the same.

## FK validator type must match the referenced PK type

When a route accepts a foreign-key id in the body, the Joi rule must match the **actual column type** of the referenced table's PK. Validating a UUID PK as `Joi.number().integer().positive()` makes the endpoint reject every legitimate id with a generic 400 — and worse, may pass review because tests only feed integers.

**Bad implementation:**

```js
// Presentation PK is a UUID (see src/database/models/presentation/index.js)
const schema_campaignConnect = {
    body: Joi.object({
        presentation_id: Joi.number().integer().positive().required(), // ❌ rejects every UUID
    }),
};
```

**good implementation**

```js
const schema_campaignConnect = {
    body: Joi.object({
        // ✅ Presentation PK is UUID
        presentation_id: Joi.string().guid({ version: ['uuidv1', 'uuidv4'] }).required(),
        leave_a_message: Joi.string().max(500).allow(null, '').optional(),
    }),
};
```

Also: prefer named constants (`appConst.USER.USER_COMPANY_TYPE.PLATFORM`) over magic numbers (`Joi.valid(1, 2)`) in validators — the moment the enum reshuffles, magic-number validators silently accept the wrong values.

Rule of thumb: before writing the validator, open the target model and check the PK column type. Never copy an integer-id pattern across modules without re-checking.

## Connect/invite flows must guard self-action, dedupe, and wrap notify in a transaction

Any "create a relation + notify the other side" flow has three failure modes that review will catch: (1) a user connects to themselves, (2) duplicates pile up when the user double-clicks, (3) the row is created but the notification or socket emit throws, leaving an orphan relation the recipient never learns about. The fix is a four-step pattern: self-check → dedupe query → transaction wraps `create + createNotification + requestEmitSocket` → commit/rollback.

**Bad implementation:**

```js
const connectFromCampaign = async (user, campaignId, presentationId, message) => {
    const campaign = await findById(CAMPAIGN, campaignId);
    const presentation = await findById(PRESENTATION, presentationId);
    // ❌ no self-connection guard
    // ❌ no dedupe — user can spam the same target
    // ❌ no transaction — notify failure leaves orphan connection
    return models[CONNECTION].create({
        sent_from: user.id,
        sent_to: presentation.user_id,
        campaign_id: campaignId,
        cv_id: presentationId,
        status: PENDING,
        leave_a_message: message || null,
    });
};
```

**good implementation**

```js
const connectFromCampaign = async (user, campaignId, presentationId, message) => {
    const [campaign, presentation] = await Promise.all([
        findById(CAMPAIGN, campaignId),
        findById(PRESENTATION, presentationId),
    ]);
    // ... existence + ownership checks ...
    if (presentation.user_id === user.id) {
        throw createError.BadRequest('cannot connect to your own presentation'); // ✅ self-check
    }

    const existing = await findOne(CONNECTION, {
        sent_from: user.id,
        sent_to: target.id,
        cv_id: presentationId,
        campaign_id: campaignId,
        status: { [Op.notIn]: [CANCELED, DEACTIVATED, DISCONNECTED] }, // ✅ dedupe only on live statuses
    });
    if (existing) throw createError.Conflict('connection already exists');

    const t = await sequelize.transaction();
    try {
        const connection = await models[CONNECTION].create({ /* ... */ }, { transaction: t });
        const notification = await createNotification(user.id, target.id, ACTION, connection.id, user, t);
        const langReceiver = await getUserLangById(target.id);
        await requestEmitSocket(notification, langReceiver); // ✅ inside txn
        await t.commit();
        return connection;
    } catch (e) {
        await t.rollback();
        throw e;
    }
};
```

Rule of thumb: any new "X-from-Y" connect/invite/share endpoint copies this skeleton verbatim — self-guard, status-aware dedupe, transactional notify. Skipping any of the three will come back as a CodeRabbit comment.

## Never double-reserve a sequence number

Atomic sequence reservers (e.g. `createQuotationWithUniqueNumber`, AFNOR/Devis no-gap counters) already burn one slot per call. Calling `getNumberQuotation(user)` beforehand and then calling the atomic creator means **every create consumes two sequence slots**, and every `PREVIEW_DRAFT` burns a real slot it will never use — both break the AFNOR "no gap" requirement and leak numbers to auditors.

**Bad implementation:**

```js
await applyQuoteCompliance({ user, customer: body.customer, body });
body.quotation_number = await getNumberQuotation(user); // ❌ reserves a seq slot
// ...
if (action === ACTION.PREVIEW_DRAFT) {
    // ❌ preview burns the real number for a throwaway PDF
    await generateAndUploadPdfQuotation({ ...dataCreateQuotation, user }, 'fr');
}
// ...
await createQuotationWithUniqueNumber(dataCreateQuotation); // reserves AGAIN
```

**good implementation**

```js
await applyQuoteCompliance({ user, customer: body.customer, body });
// ✅ no pre-reservation — the atomic creator owns the sequence
if (action === ACTION.PREVIEW_DRAFT) {
    dataCreateQuotation.quotation_number = '[PREVIEW]'; // ✅ placeholder, no seq burned
    await generateAndUploadPdfQuotation({ ...dataCreateQuotation, user }, 'fr');
}
// ...
await createQuotationWithUniqueNumber(dataCreateQuotation); // ✅ single reservation
```

Rule of thumb: any "atomic reserver" helper is the **only** place a sequence is consumed. Previews, drafts, and dry-runs get a hardcoded placeholder.

## Use `??` (not `||`) when zero is a legitimate value

`||` treats `0`, `''`, and `false` as falsy and falls through to the next operand. For monetary fields (`total_paid`, `total_ttc`, `total_remains`), discounts, and counters, `0` is a real value — using `||` silently rewrites a legitimate zero into the previous DB value, which can clobber `total_remains` to wrong amounts and ship invoices with incorrect "amount due".

**Bad implementation:**

```js
// body.total_paid = 0 (client zeroed the paid amount)
body.total_remains =
    (body.total_ttc || quotation.total_ttc || 0) - (body.total_paid || quotation.total_paid || 0);
// ❌ 0 falls through to quotation.total_paid → total_remains computed against stale paid value
```

**good implementation**

```js
body.total_remains =
    (body.total_ttc ?? quotation.total_ttc ?? 0) - (body.total_paid ?? quotation.total_paid ?? 0);
// ✅ only null/undefined fall through; explicit 0 from the client is respected
```

Rule of thumb: for any numeric, boolean, or money field where `0`/`false`/`''` is meaningful, default with `??`. Reserve `||` for "string is empty OR missing" cases where you actually want both treated the same.

## FK validator type must match the referenced PK type

When a route accepts a foreign-key id in the body, the Joi rule must match the **actual column type** of the referenced table's PK. Validating a UUID PK as `Joi.number().integer().positive()` makes the endpoint reject every legitimate id with a generic 400 — and worse, may pass review because tests only feed integers.

**Bad implementation:**

```js
// Presentation PK is a UUID (see src/database/models/presentation/index.js)
const schema_campaignConnect = {
    body: Joi.object({
        presentation_id: Joi.number().integer().positive().required(), // ❌ rejects every UUID
    }),
};
```

**good implementation**

```js
const schema_campaignConnect = {
    body: Joi.object({
        // ✅ Presentation PK is UUID
        presentation_id: Joi.string().guid({ version: ['uuidv1', 'uuidv4'] }).required(),
        leave_a_message: Joi.string().max(500).allow(null, '').optional(),
    }),
};
```

Also: prefer named constants (`appConst.USER.USER_COMPANY_TYPE.PLATFORM`) over magic numbers (`Joi.valid(1, 2)`) in validators — the moment the enum reshuffles, magic-number validators silently accept the wrong values.

Rule of thumb: before writing the validator, open the target model and check the PK column type. Never copy an integer-id pattern across modules without re-checking.

## Connect/invite flows must guard self-action, dedupe, and wrap notify in a transaction

Any "create a relation + notify the other side" flow has three failure modes that review will catch: (1) a user connects to themselves, (2) duplicates pile up when the user double-clicks, (3) the row is created but the notification or socket emit throws, leaving an orphan relation the recipient never learns about. The fix is a four-step pattern: self-check → dedupe query → transaction wraps `create + createNotification + requestEmitSocket` → commit/rollback.

**Bad implementation:**

```js
const connectFromCampaign = async (user, campaignId, presentationId, message) => {
    const campaign = await findById(CAMPAIGN, campaignId);
    const presentation = await findById(PRESENTATION, presentationId);
    // ❌ no self-connection guard
    // ❌ no dedupe — user can spam the same target
    // ❌ no transaction — notify failure leaves orphan connection
    return models[CONNECTION].create({
        sent_from: user.id,
        sent_to: presentation.user_id,
        campaign_id: campaignId,
        cv_id: presentationId,
        status: PENDING,
        leave_a_message: message || null,
    });
};
```

**good implementation**

```js
const connectFromCampaign = async (user, campaignId, presentationId, message) => {
    const [campaign, presentation] = await Promise.all([
        findById(CAMPAIGN, campaignId),
        findById(PRESENTATION, presentationId),
    ]);
    // ... existence + ownership checks ...
    if (presentation.user_id === user.id) {
        throw createError.BadRequest('cannot connect to your own presentation'); // ✅ self-check
    }

    const existing = await findOne(CONNECTION, {
        sent_from: user.id,
        sent_to: target.id,
        cv_id: presentationId,
        campaign_id: campaignId,
        status: { [Op.notIn]: [CANCELED, DEACTIVATED, DISCONNECTED] }, // ✅ dedupe only on live statuses
    });
    if (existing) throw createError.Conflict('connection already exists');

    const t = await sequelize.transaction();
    try {
        const connection = await models[CONNECTION].create({ /* ... */ }, { transaction: t });
        const notification = await createNotification(user.id, target.id, ACTION, connection.id, user, t);
        const langReceiver = await getUserLangById(target.id);
        await requestEmitSocket(notification, langReceiver); // ✅ inside txn
        await t.commit();
        return connection;
    } catch (e) {
        await t.rollback();
        throw e;
    }
};
```

Rule of thumb: any new "X-from-Y" connect/invite/share endpoint copies this skeleton verbatim — self-guard, status-aware dedupe, transactional notify. Skipping any of the three will come back as a CodeRabbit comment.


## Null-guard enum mappers before pattern matching

Lookup helpers that map external/database values to enum buckets must handle `null`/`undefined` inputs explicitly. Forwarding a missing value into a chained `if`/`switch` falls through to the default case, silently producing a wrong label (e.g. `OTHER`) instead of propagating "unknown". Treat absence as its own case and return `null` so the caller can distinguish "no data" from "data outside the known set".

**Bad implementation:**

```js
const contactTypeToProspectType = (contactType) => {
  if (contactType === COMPANY) { return PROSPECT_TYPE.B2B; }
  if (contactType === INDIVIDUAL) { return PROSPECT_TYPE.B2C; }
  return PROSPECT_TYPE.OTHER; // ❌ undefined/null becomes OTHER
};
```

**Good implementation:**

```js
const contactTypeToProspectType = (contactType) => {
  if (contactType === null || contactType === undefined) { return null; } // ✅ explicit
  if (contactType === COMPANY) { return PROSPECT_TYPE.B2B; }
  if (contactType === INDIVIDUAL) { return PROSPECT_TYPE.B2C; }
  return PROSPECT_TYPE.OTHER;
};
```

Apply the same rule to every sibling mapper (status→bucket, role→permission, etc.) so null-handling is consistent across the file.


## Use `individualHooks: true` on bulk Sequelize updates that must trigger model hooks

`Model.update({...}, { where })` runs as a single SQL statement and skips `beforeUpdate`/`afterUpdate` per-row hooks by default. If downstream logic (cache invalidation, score recompute, audit logs) lives in those hooks, the side effect silently vanishes whenever the bulk path is taken. Pass `individualHooks: true` whenever the hook must fire — and document the perf trade-off when batches are large.

**Bad implementation:**

```js
await models.BusinessOpportunityAssignment.update(
  { processed_at: now },
  { where: { business_opportunity_id: id, processed_at: null }, transaction }
); // ❌ afterUpdate scoring hook never fires
```

**Good implementation:**

```js
await models.BusinessOpportunityAssignment.update(
  { processed_at: now },
  {
    where: { business_opportunity_id: id, processed_at: null },
    transaction,
    individualHooks: true, // ✅ afterUpdate runs for each affected row
  }
);
```

Rule of thumb: if a model declares a row-level `afterUpdate`/`afterDestroy` hook with real side effects, every call site doing a bulk `update`/`destroy` must opt into `individualHooks` or explicitly call the side effect manually.


## Wrap read-then-write controller actions in a single transaction

Endpoints that read state and immediately persist a derived value (recalc, recompute, materialize) must run inside `sequelize.transaction` so the read snapshot and the write are atomic. Without it, a concurrent mutation between the SELECT and the UPDATE produces a stale stored value — and the bug is invisible until a race actually happens.

**Bad implementation:**

```js
const recalculateScore = async (req, res) => {
  const result = await scoringService.computeProspectScore(Number(req.params.id));
  // ❌ another writer can mutate inputs between read and persist
  return res.json(result);
};
```

**Good implementation:**

```js
const recalculateScore = async (req, res) => {
  const result = await sequelize.transaction((t) =>
    scoringService.computeProspectScore(Number(req.params.id), t) // ✅ atomic snapshot + write
  );
  if (!result) { throw createError(404, 'business_opportunity_not_found'); }
  return res.json(result);
};
```

The downstream service must accept the transaction parameter and forward it to every `findOne`/`update` it issues, otherwise the wrapping is cosmetic.


## Cap fan-out work inside model hooks

A hook that recomputes "all children of this parent" is a latent O(N) bomb: a tenant with 10k child rows turns a single `Customer.update` into a 10k-row transaction. Always bound the fan-out with a `limit`, log when the cap is hit, and move the overflow to an async job. The cap protects request latency, lock duration, and replication lag in one shot.

**Bad implementation:**

```js
const bos = await models.BusinessOpportunity.findAll({
  where: { customer_id: customer.id },
  attributes: ['id'],
  transaction,
}); // ❌ unbounded — fan-out scales with tenant size
for (const bo of bos) { await computeProspectScore(bo.id, transaction); }
```

**Good implementation:**

```js
const MAX_HOOK_RECOMPUTE = 200;

const bos = await models.BusinessOpportunity.findAll({
  where: { customer_id: customer.id },
  attributes: ['id'],
  transaction,
  limit: MAX_HOOK_RECOMPUTE + 1, // ✅ fetch one extra to detect overflow
});
if (bos.length > MAX_HOOK_RECOMPUTE) {
  console.warn('hook recompute capped', { customer_id: customer.id, cap: MAX_HOOK_RECOMPUTE });
  bos.length = MAX_HOOK_RECOMPUTE; // ✅ truncate, enqueue the rest elsewhere
}
for (const bo of bos) { await computeProspectScore(bo.id, transaction); }
```

Whenever you add a hook that touches "all related X", define the cap in the same commit. Discovering the missing cap in production via a 30-second transaction is much more expensive than the five lines it takes to add upfront.


## Use Joi's `helpers.message` for custom validation messages, not `helpers.error('any.invalid', ...)`

Inside a Joi `.custom()` validator, `helpers.error('any.invalid', { message: '...' })` does NOT surface the custom string — it triggers the built-in `any.invalid` label and your `message` field is silently dropped, leaving the client with a generic `"value" contains an invalid value` error. To return a tailored message, use `helpers.message({ custom: '...' })` (or `helpers.message('...')`), which Joi renders verbatim. This matters because the front-end depends on these strings to drive UX feedback ("sum exceeds 100", "duplicate commercial_id", etc.).

**Bad implementation:**

```js
.custom((value, helpers) => {
  if (sum > 100) {
    return helpers.error('any.invalid', { message: 'sum of percentages exceeds 100' });
    // ❌ client receives generic "any.invalid" — message is lost
  }
  return value;
})
```

**Good implementation:**

```js
.custom((value, helpers) => {
  if (sum > 100) {
    return helpers.message({ custom: 'sum of percentages exceeds 100' }); // ✅ surfaced as-is
  }
  return value;
})
```

If you need a stable error code instead of a string, define a real Joi error template via `.messages({ 'my.code': '...' })` and emit it with `helpers.error('my.code')`. The one thing that never works is `helpers.error(..., { message })` — that combination silently swallows the message every time.

---

## Guard `transaction.rollback()` against secondary failures in per-row catch blocks

In bulk-import / batch endpoints that open a fresh transaction per item and catch errors to continue processing, an unguarded `await transaction.rollback()` inside the `catch` can itself throw (e.g. the connection was already closed, the transaction was already finalized, or a deadlock victim was rolled back by the DB). That secondary error then bubbles out of the per-row `catch`, aborts the loop, and masks the original row error — so a single transient DB hiccup kills the rest of the import instead of being recorded as one failed row.

Wrap the rollback in its own `try/catch`, log the rollback error, and let the outer loop continue. Keep pushing the **sanitized** original reason into the per-row error report.

**Bad implementation:**

```js
for (const record of records) {
  const transaction = await sequelize.transaction();
  try {
    await Customer.create(payload, { transaction });
    await transaction.commit();
  } catch (err) {
    await transaction.rollback(); // ❌ if this throws, it escapes the loop and stops the whole import
    errors.push({ line: rowNumber, reason: err.message });
  }
}
```

**Good implementation:**

```js
for (const record of records) {
  const transaction = await sequelize.transaction();
  try {
    await Customer.create(payload, { transaction });
    await transaction.commit();
  } catch (err) {
    try {
      await transaction.rollback();
    } catch (rollbackErr) {
      console.error(`importBusinessOpportunity row ${rowNumber} rollback error:`, rollbackErr);
    }
    console.error(`importBusinessOpportunity row ${rowNumber} error:`, err);
    errors.push({ line: rowNumber, reason: 'unexpected error' }); // sanitized, no err.message leak
  }
}
```

The same pattern applies to any `finally`-style cleanup (`stream.destroy()`, `lock.release()`, `client.quit()`) that runs in the failure path of a loop: secondary cleanup errors must never be allowed to abort the surrounding iteration.

## Subtract tenant-resolved statuses from static bucket maps to avoid overlap

When a "qualified" bucket is dynamically resolved per tenant (e.g. from `crm_setting.status_classification.positive`) but the other buckets (`new`, `contacted`, `lost`) are still derived from a static `PROSPECT_BUCKET_MAP`, a status the tenant classified as positive can also live in a static non-qualified bucket. The bucket filter then returns the same row under two different labels depending on which bucket was queried, and the serializer's `prospect_bucket` field disagrees with the filter. Always subtract the tenant-resolved set from the static buckets before applying the `IN(...)` clause, so each status maps to exactly one bucket for the current tenant.

**Bad implementation:**

```js
if (bucket && PROSPECT_BUCKET_MAP[bucket]) {
  const bucketStatuses = bucket === 'qualified'
    ? qualifiedStatuses
    : PROSPECT_BUCKET_MAP[bucket]; // ❌ may still contain a status the tenant marked qualified
  boWhere.status = { [Op.in]: bucketStatuses.filter((s) => s !== WASTE) };
}
```

**Good implementation:**

```js
if (bucket && PROSPECT_BUCKET_MAP[bucket]) {
  const qualifiedSet = new Set(qualifiedStatuses);
  const bucketStatuses = bucket === 'qualified'
    ? qualifiedStatuses
    : PROSPECT_BUCKET_MAP[bucket].filter((s) => !qualifiedSet.has(s));
  boWhere.status = { [Op.in]: bucketStatuses.filter((s) => s !== WASTE) };
}
```

The same rule applies to `toProspectBucket(status, qualifiedStatuses)`: it must check the tenant-resolved set first and skip the qualified entry of the static map when iterating, so a single status never resolves to two buckets.

## Match the module's existing route/validator conventions when adding a sibling endpoint

A new GET/POST that joins an existing module router must mirror the conventions its siblings already use — `validate(schema, { context: true })`, a `try/catch` wrapper in the controller, shared validators (`sourceValidator`, `searchValidator`) and shared constants (`CSV_DEFAULTS.DELIMITER`, app-level `PROSPECT_BUCKETS`) — not reinvent them. Local one-offs (a fresh `Joi.string().max(100)` next to a sibling using `sourceValidator`, a hardcoded `';'` next to `CSV_DEFAULTS.DELIMITER`, missing `{ context: true }` on a route whose sibling needs it) cause subtle divergence: validation rules drift between sibling routes, formula-injection sanitisation only protects half of them, and a future change to the shared validator silently fails to propagate.

**Bad implementation:**

```js
// router
router.get('/export-csv',
  asyncMiddleware(checkLogin),
  validate(schema_exportProspectsForManager),       // ❌ sibling routes use { context: true }
  asyncMiddleware(exportBusinessOpportunitiesForManager));

// validator
const schema_exportProspectsForManager = {
  query: Joi.object({
    source: Joi.string().max(100).optional(),       // ❌ duplicates sibling's sourceValidator
    ...
  }),
};

// controller
let csv = rows.length
  ? convertObjectsToCSV(rows, { columns: EXPORT_COLUMNS, sanitize: true })
  : EXPORT_COLUMNS.join(';');                       // ❌ hardcoded delimiter
```

**Good implementation:**

```js
router.get('/export-csv',
  asyncMiddleware(checkLogin),
  validate(schema_exportProspectsForManager, { context: true }),
  asyncMiddleware(exportBusinessOpportunitiesForManager));

const schema_exportProspectsForManager = {
  query: Joi.object({
    source: sourceValidator,
    ...
  }).oxor('assignee_id', 'unassigned'),
};

const { convertObjectsToCSV, CSV_DEFAULTS } = require('../../helpers/csv.helper');
let csv = rows.length
  ? convertObjectsToCSV(rows, { columns: EXPORT_COLUMNS, sanitize: true })
  : EXPORT_COLUMNS.join(CSV_DEFAULTS.DELIMITER);
```

Before merging a new route, diff its router/validator/controller against the file's nearest sibling and align: same `validate()` options, same shared validators, same shared constants, same `try/catch` shape.

## Promote module-local constants to `appConst` once a second module needs them

Constants like `PROSPECT_BUCKET_MAP`, `PROSPECT_TYPE`, `PROSPECT_TYPE_CONTACT_TYPES` initially live in a single serializer because only one module reads them. The moment a second consumer appears (export-csv reusing the manager-list shape), copy-pasting or re-importing them across modules guarantees drift: one module updates the map, the other does not, and a status silently moves between buckets in only half the responses. Move the constants to `helpers/constant.helper.js` under their canonical namespace (`BUSINESS_OPPORTUNITY.PROSPECT_BUCKET_MAP`) and import them everywhere; delete the duplicated module-local copies in the same PR.

**Bad implementation:**

```js
// serializer.prospect.business-opportunity.js
const BUCKET = { NEW: 'new', CONTACTED: 'contacted', QUALIFIED: 'qualified', LOST: 'lost' };
const BUCKET_MAP = { ... };
const PROSPECT_TYPE_TO_CONTACT_TYPES = { ... };
module.exports = { BUCKET, BUCKET_MAP, PROSPECT_TYPE_TO_CONTACT_TYPES };

// validator.business-opportunity.js
const { BUCKET, PROSPECT_TYPE } = require('./serializer.prospect.business-opportunity');
// new export-csv schema starts importing from the serializer too — coupling grows.
```

**Good implementation:**

```js
// helpers/constant.helper.js
BUSINESS_OPPORTUNITY: {
  ...,
  PROSPECT_BUCKET_MAP: { new: [0], contacted: [2, 3, 4], qualified: [6, 7, 8, 9], lost: [1, 5, 10] },
  PROSPECT_TYPE: { B2B: 'B2B', B2C: 'B2C', OTHER: 'OTHER' },
  PROSPECT_TYPE_CONTACT_TYPES: { B2B: [0], B2C: [1], OTHER: [2, 3, 4, 5, 6] },
},

// validator + service + serializer all import from appConst
const { PROSPECT_BUCKET_MAP, PROSPECT_TYPE, PROSPECT_TYPE_CONTACT_TYPES } = appConst.BUSINESS_OPPORTUNITY;
```

Rule of thumb: as soon as a constant has two import paths, it has one source of truth too many — promote it.

## Use `req.lang` (with a default fallback) instead of reading `accept-language` directly

The codebase has an i18n middleware that normalizes the requested locale and exposes it on `req.lang`. Reading `req.headers['accept-language']` directly in a middleware or controller bypasses that normalization: the raw header can be `undefined`, a complex list (`fr-FR,fr;q=0.9,en;q=0.8`), or an unsupported locale, and any downstream `commonMessage(lang)` call then silently falls back to an empty/undefined translation bucket — producing error responses with missing messages. Always pull the locale from `req.lang` and fall back to `appConst.HEADER.LOCALE_DEFAULT` when it is absent, so every layer agrees on the same resolved language.

**Bad implementation:**

```js
const requireProspectsModule = async (req, res, next) => {
  try {
    const lang = req.headers['accept-language'];

    if (!FEATURE_FLAGS.PROSPECTS_MODULE) {
      throw createApiError(403, commonMessage(lang).FEATURE_DISABLED, ERROR_CODE.FEATURE_DISABLED);
    }
    ...
```

**Good implementation:**

```js
const requireProspectsModule = async (req, res, next) => {
  try {
    const lang = req.lang || appConst.HEADER.LOCALE_DEFAULT;

    if (!FEATURE_FLAGS.PROSPECTS_MODULE) {
      throw createApiError(403, commonMessage(lang).FEATURE_DISABLED, ERROR_CODE.FEATURE_DISABLED);
    }
    ...
```

Rule of thumb: in any middleware/controller that builds a translated error, the locale source is `req.lang`, never the raw header.

## Idempotency guard before re-triggering a side-effecting sync

When a polling/read endpoint also pushes terminal state into a webhook/sync pipeline, compare the incoming terminal status against the already-persisted status and short-circuit when they are equal. Re-processing an already-synced terminal event is at best wasted work and at worst double side effects (duplicate notifications, status flapping, redundant external calls). Source the persisted value from the entity you already loaded for ownership/authorization rather than issuing another query. (Lesson from yhnlvy's fix commit `83c587a` on PR #1123 — "short-circuit getDocv sync when already synced".)

**Bad implementation:**

```js
static async getDocv(user, verificationId, lang = LOCALE_DEFAULT) {
  await this._loadOwnedDocReg(user, verificationId, lang); // loaded only for side effect, return discarded

  const details = await OnboardingAPI.getDocvDetails(verificationId);
  const statusLower = String(ubbleStatus).toLowerCase();
  const isTerminal =
    UBBLE_SUCCESS_STATUSES.includes(statusLower) || UBBLE_FAILURE_STATUSES.includes(statusLower);

  if (isTerminal) {
    // fires every poll even if DOCV is already in this terminal state
    await DocvWebhookService.processDocvWebhook(verificationId, ubbleStatus, details, lang);
  }
}
```

**good implementation**

```js
static async getDocv(user, verificationId, lang = LOCALE_DEFAULT) {
  const documentRegistration = await this._loadOwnedDocReg(user, verificationId, lang);

  const details = await OnboardingAPI.getDocvDetails(verificationId);
  const statusLower = String(ubbleStatus).toLowerCase();
  const isTerminal =
    UBBLE_SUCCESS_STATUSES.includes(statusLower) || UBBLE_FAILURE_STATUSES.includes(statusLower);
  const alreadySynced =
    (documentRegistration.docv_verification_status || '').toLowerCase() === statusLower;

  if (isTerminal && !alreadySynced) {
    await DocvWebhookService.processDocvWebhook(verificationId, statusLower, details, lang);
  }
}
```

## Normalize values once and log caught errors with full context

Normalize an external value a single time and pass the normalized form to every downstream consumer instead of re-normalizing (or, worse, passing the raw form to one consumer and the normalized form to another) — divergent representations of the same field cause subtle comparison/storage bugs. In the catch block of a best-effort side effect, use optional chaining on the error and include the stack so a swallowed failure remains diagnosable. (Lesson from yhnlvy's fix commit `83c587a` on PR #1123.)

**Bad implementation:**

```js
const statusLower = String(ubbleStatus).toLowerCase();
try {
  // raw ubbleStatus sent downstream while comparisons elsewhere use statusLower
  await DocvWebhookService.processDocvWebhook(verificationId, ubbleStatus, details, lang);
} catch (err) {
  logger.error('Failed to sync DOCV status from polling', {
    verificationId,
    ubbleStatus,
    error: err.message, // throws if err is null/undefined; no stack
  });
}
```

**good implementation**

```js
const statusLower = String(ubbleStatus).toLowerCase();
try {
  await DocvWebhookService.processDocvWebhook(verificationId, statusLower, details, lang);
} catch (err) {
  logger.error('Failed to sync DOCV status from polling', {
    verificationId,
    ubbleStatus,
    error: err?.message,
    stack: err?.stack,
  });
}
```

## Bound every secondary "fetch related rows" query, not just the paginated one

When a paginated endpoint runs a second query to hydrate details for the
current page (e.g. fetching all invoices belonging to the page's customers),
that follow-up query must also be capped. Paginating the primary aggregate
does NOT bound the detail query: a single customer with thousands of unpaid
invoices can still load an unbounded result set into memory. Derive an explicit
limit from the page size (e.g. `perCustomerCap * pageCustomerIds.length`) so
the detail fetch stays proportional to the page. Also strip internal fields
(like `result.user`) before responding, consistently with sibling controllers.

**Bad implementation:**

```
const customerIds = rows.map((r) => r.customer_id);
const [customers, invoices] = await Promise.all([
	find(CUSTOMER, { id: { [Op.in]: customerIds } }, null, {
		attributes: ['id', 'company_name'],
	}),
	// No limit: a customer with many unpaid invoices loads everything.
	find(INVOICE, { ...where, customer_id: { [Op.in]: customerIds } }, null, {
		attributes: ['id', 'invoice_number', 'total_remains', 'customer_id'],
		order: [['created_on', 'DESC']],
	}),
]);

// Controller returns the raw service result, leaking internal fields.
const result = await invoiceService.getDebtByCustomer(req.user, req.query);
return res.json(result);
```

**good implementation**

```
const customerIds = rows.map((r) => r.customer_id);
// Cap detail rows so the response stays proportional to the page size.
const INVOICE_DETAIL_CAP = 50 * customerIds.length;
const [customers, invoices] = await Promise.all([
	find(CUSTOMER, { id: { [Op.in]: customerIds } }, null, {
		attributes: ['id', 'company_name'],
	}),
	find(INVOICE, { ...where, customer_id: { [Op.in]: customerIds } }, null, {
		attributes: ['id', 'invoice_number', 'total_remains', 'customer_id'],
		order: [['created_on', 'DESC']],
		limit: INVOICE_DETAIL_CAP,
	}),
]);

// Controller drops internal fields before responding, like its siblings.
const result = await invoiceService.getDebtByCustomer(req.user, req.query);
delete result?.user;
return res.json(result);
```
