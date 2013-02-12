Package.describe({
  summary: "Adds undo, redo, versioning, basic operational transformation (OT) and transactions to Meteor collections."
});

Package.on_use(function (api, where) {
  where = where || ['client', 'server'];
  api.use(['underscore', 'logger', 'i18n'], where);
  api.add_files('crdt.js', where);
  api.add_files('crdts.js', where);
  api.add_files('transactions.js', where);
});
