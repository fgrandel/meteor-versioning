Package.describe({
  summary: "Undo/redo, improved conflict resolution and transactions for Meteor collections."
});

Package.on_use(function (api, where) {
  where = where || ['client', 'server'];
  api.use(['underscore', 'logger', 'i18n', 'mongo-livedata', 'livedata', 'random'], where);
  api.add_files('crdt.js', where);
  api.add_files('versioned-collection.js', where);
  api.add_files('transactions.js', where);
  api.add_files('messages.js', where);
});
