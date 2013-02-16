# Transaction service
class Meteor._TransactionsManager
  # Versioned collections registered to the tx manager.
  _collections: {}

  # Operations queued for the current transaction.
  _currentOps: []

  # Transactions that arrived out of order.
  _pendingTxs: []

  # Internal undo/redo logs.
  _undoStack: []
  _redoStack: []

  constructor: ->
    if Meteor.isServer
      @_localSite = 'server'
    else
      @_localSite = 'client-' + Meteor.uuid()

    # On the server: Create the transactions log.
    if Meteor.isServer
      transactions = new Meteor.Collection 'transactions'
      @purgeLog = -> transactions.remove {}

    # Execute transactions in a meteor method so that
    # we can simulate their effect locally without latency
    # and without having to give clients write access to
    # the underlying collections.
    # TODO: Implement security so that changes from the
    # client can be disallowed.
    self = @
    Meteor.methods
      _executeTx: (tx) ->
        # Log the transaction.
        tx._id = transactions.insert tx unless @isSimulation
        # Execute the transaction.
        self._execute tx

  # Get the clock component corresponding to the given site.
  _getTick: (clock, site) ->
    clock[site] = 0 unless clock[site]?
    clock[site]

  # Check whether an event at time clock1 happened-before an
  # event at time clock2.
  _happenedBefore: (clock1, clock2) ->
    # Identify the participating sites.
    sites = _.union _.keys(clock1), _.keys(clock2)

    # Run through all sites and check whether for all of them
    # tx1's clock is less than or equal tx2's clock and for
    # at least one of the sites tx1's clock is strictly less.
    didHappenBefore = false
    for site in sites
      clockComponent1 = @_getTick clock1, site
      clockComponent2 = @_getTick clock2, site
      if clockComponent1 > clockComponent2
        # We found a component of tx1's clock that is not less
        # than or equal the corresponding component of tx2's
        # clock. So tx1 can not have happened before tx2.
        return false
      if clockComponent1 < clockComponent2
        # We found a component of tx1's clock that is strictly
        # less than tx2's clock. If all other clocks are less
        # or equal, then tx1 happend-before tx2.
        didHappenBefore = true
    didHappenBefore

  _getTxId: (tx) -> if tx._id? then tx._id else 'simulated'

  _addCollection: (collection) ->
    @_collections[collection._name] = collection

  _getCollection: (collection) -> @_collections[collection]

  _addOperation: (operation) -> @_currentOps.push operation

  # Make a few consistency checks and add the transaction
  # to the pendingTxs cache.
  _addPending: (tx) ->
    txId = @_getTxId(tx)
    txSite = tx.initiatingSite
    outOfOrder = false
    for op in tx.operations
      # Establish the CRDT clock vector that was current just before the
      # given operation was executed. The given operation
      # causally depends on all CRDT versions that happened-before
      # this base clock.
      opClock = op.clock
      baseClock = _.clone opClock
      baseClock[txSite] = (@_getTick opClock, txSite) - 1
      console.assert baseClock[txSite] >= 0
      op.baseClock = baseClock

      # Find the last CRDT version clock.
      crdt = @_collections[op.collection]._getCrdt op.crdtId
      lastClock = if crdt? then crdt.clock else {}

      # Check whether the operation has already been executed, i.e.
      # we have already executed an operation on the CRDT that
      # causally depends on this transaction.
      if @_happenedBefore baseClock, lastClock
        Meteor.log.error 'transaction.receivedDuplicateTx'
          site: txSite
          tx: txId
        return false

      # Check whether the transaction arrived out of order.
      if @_happenedBefore lastClock, baseClock then outOfOrder = true

    if outOfOrder
      Meteor.log.warning 'transaction.arrivedOutOfOrder',
        site: txSite
        tx: txId

    @_pendingTxs.push tx

  # Roll back the given transaction.
  _abort: (tx, txColls) ->
    txId = @_getTxId(tx)
    Meteor.log.warning 'transaction.aborting', tx: txId
    # TODO: Roll back already executed operations.
    # TODO: What are we doing with the clocks?
    for name, coll of txColls
      coll._txAbort()

  _doTransaction: (tx) ->
    txId = @_getTxId(tx)
    txSite = tx.initiatingSite

    # Execute all operations in the pending transaction.
    txColls = {}
    for op in tx.operations
      try
        # Find the collection
        coll = @_collections[op.collection]
        console.assert coll?

        # Start the transaction in the collection if necessary.
        if not txColls[coll._name]
          txColls[coll._name] = coll
          coll._txStart()

        # Execute the operation.
        args = if op.args? then op.args else {}
        op.result = coll._ops[op.op] op.crdtId, args, op.clock, txSite
      catch e
        Meteor.log.error 'transaction.operationProducedError',
          op: op.op
          tx: txId
          message: if _.isString e then e else e.message
        # Roll back already executed operations.
        @_abort tx, txColls
        return false

    # Commit should be atomic to provide perfect tx isolation.
    # Unfortunately we cannot do an atomic update of various objects in
    # (Mini)MongoDB or in a reactive environment like Meteor where
    # each data change may trigger a synchronous update to the interface.
    # We try to get as close as possible by collecting all operations and
    # executing them in one call stack.

    # In practice this means that observer methods can see inconsistent
    # data but new cursors will always see consistent data. With a client
    # library like AngularJS you can further improve on this by applying
    # data changes to the interface only after all data has been updated.
    # At least for my use cases that is perfectly ok.

    # Commit the transaction.
    for name, coll of txColls
      coll._txCommit()
    true

  # Execute the transaction (or queue it if it arrived out of order).
  _execute: (tx) ->
    # Add the transaction to the pending transactions cache.
    @_addPending tx

    while true
      # Find the first pending transaction that can be executed.
      # To preserve causality ('happened before'), we will have
      # to check whether the predecessor transactions of a
      # transaction have been executed.
      executableTx = null
      for pendingTx, i in @_pendingTxs
        # If for one of the operations, our local CRDT clock
        # happened-before the operation's base clock
        # then we are missing a prior transaction that this
        # transaction causally depends on.
        executableTx = pendingTx
        for op in pendingTx.operations
          collection = @_collections[op.collection]
          crdt = collection._getCrdt op.crdtId
          lastClock = if crdt? then crdt.clock else {}
          if @_happenedBefore lastClock, op.baseClock
            # Do not execute the transaction
            executableTx = null
            break
        if executableTx?
          # We found an executable transaction, so
          # remove it from the pending transactions.
          @_pendingTxs.splice i, 1
          break
      return true unless executableTx?

      # Execute the transaction.
      initiatingSite = executableTx.initiatingSite
      Meteor.log.info 'transaction.nowExecuting',
        site: initiatingSite
        tx: @_getTxId(executableTx)
      return false unless @_doTransaction executableTx

      # If this is a local transaction that is not an undo
      # transaction itself then push it to the undo stack.
      if initiatingSite == @_localSite and not executableTx.isUndo
        @_undoStack.push executableTx.operations

  # Advance the local clock by one tick.
  _ticTac: (clock) ->
    clock = {} unless clock?
    clock[@_localSite] = (@_getTick clock, @_localSite) + 1
    clock

  # Queue and execute operations as a transaction.
  _queueInternal: (operations, isUndo = false) ->
    # Advance the CRDT version clocks.
    for op in operations
      crdt = @_collections[op.collection]._getCrdt op.crdtId
      op.clock = @_ticTac crdt?.clock
    # Build the transaction.
    tx =
      initiatingSite: @_localSite
      isUndo: isUndo
      operations: operations
    # Execute the transaction.
    Meteor.call '_executeTx', tx


  ##################
  # Public Methods #
  ##################
  commit: ->
    # Committing a new local transaction will delete the redo stack.
    @_redoStack = []

    # Queue the transaction for local and remote execution.
    @_queueInternal @_currentOps
    @_currentOps = []

  rollback: -> @_currentOps = []

  undo: ->
    if @_undoStack.length == 0
      Meteor.log.info 'transaction.nothingToUndo'
      return

    # Get a transaction from the undo stack.
    undoTx = @_undoStack.pop()

    # Create a transaction that contains the inverse of all its
    # operations in reverse order.
    undoOperations = []
    for originalOperation in (undoTx.slice 0).reverse()
      undoOperations.push
        op: 'inverse'
        collection: originalOperation.collection
        crdtId: originalOperation.crdtId
        args:
          op: originalOperation.op
          args: originalOperation.args
          result: originalOperation.result

    # Queue the undo transaction.
    @_queueInternal undoOperations, true

    # Push the undone transaction onto the redo stack.
    @_redoStack.push undoTx

  redo: ->
    if @_redoStack.length == 0
      Meteor.log.info 'transaction.nothingToRedo'
      return

    # Take the last undone transaction from the redo stack.
    redoTx = @_redoStack.pop()

    # Execute the redo transaction.
    @_queueInternal redoTx


# Singleton
Meteor._TransactionsManager = new Meteor._TransactionsManager

# Add a shortcut
Meteor.tx = Meteor._TransactionsManager
