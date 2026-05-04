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
