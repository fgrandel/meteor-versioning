# Transaction service
class Meteor._TransactionsManager
  constructor: ->
    if Meteor.isServer
      localSite = 'server'
    else
      localSite = 'client-' + Meteor.uuid()

    pendingTxs = []

    undoStack = []
    redoStack = []

    currentOps = []

    # Get the clock component corresponding to the given site.
    getTick = (clock, site) =>
      clock[site] = 0 unless clock[site]?
      clock[site]

    # Advance the local clock by one tick.
    ticTac = (clock) =>
      clock = {} unless clock?
      clock[localSite] = (getTick clock, localSite) + 1
      clock

    # Check whether an event at time clock1 happened-before an
    # event at time clock2.
    happenedBefore = (clock1, clock2) =>
      # Identify the participating sites.
      sites = _.union _.keys(clock1), _.keys(clock2)

      # Run through all sites and check whether for all of them
      # tx1's clock is less than or equal tx2's clock and for
      # at least one of the sites tx1's clock is strictly less.
      didHappenBefore = false
      for site in sites
        clockComponent1 = getTick clock1, site
        clockComponent2 = getTick clock2, site
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

    getTxId = (tx) -> if tx._id? then tx._id else 'simulated'

    crdtManager = Meteor._CrdtManager

    # Make a few consistency checks and add the transaction
    # to the pendingTxs cache.
    addPending = (tx) =>
      txId = getTxId(tx)
      txSite = tx.initiatingSite
      outOfOrder = false
      for op in tx.operations
        # Establish the CRDT clock vector that was current just before the
        # given operation was executed. The given operation
        # causally depends on all CRDT versions that happened-before
        # this base clock.
        opClock = op.clock
        baseClock = _.clone opClock
        baseClock[txSite] = (getTick opClock, txSite) - 1
        console.assert baseClock[txSite] >= 0
        op.baseClock = baseClock

        # Find the last CRDT version clock.
        crdt = crdtManager.findCrdt op.collection, op.crdtId
        lastClock = if crdt? then crdt.clock else {}

        # Check whether the operation has already been executed, i.e.
        # we have already executed an operation on the CRDT that
        # causally depends on this transaction.
        if happenedBefore baseClock, lastClock
          Meteor.log.error 'transaction.receivedDuplicateTx'
            site: txSite
            tx: txId
          return false

        # Check whether the transaction arrived out of order.
        if happenedBefore lastClock, baseClock then outOfOrder = true

      if outOfOrder
        Meteor.log.warning 'transaction.arrivedOutOfOrder',
          site: txSite
          tx: txId

      pendingTxs.push tx

    # Roll back the given transaction.
    abort = (tx) =>
      txId = getTxId(tx)
      Meteor.log.warning 'transaction.aborting', tx: txId
      # TODO: Roll back already executed operations.
      # TODO: What are we doing with the clocks?
      crdtManager.txAbort()

    doTransaction = (tx) =>
      txId = getTxId(tx)

      # Start the transaction.
      crdtManager.txStart()

      # Execute all operations in the pending transaction.
      for op in tx.operations
        try
          # Execute the operation.
          args = if op.args? then op.args else {}
          op.result = crdtManager[op.op] op.collection, op.crdtId,
            args, op.clock
        catch e
          Meteor.log.error 'transaction.operationProducedError',
            op: op.op
            tx: txId
            message: if _.isString e then e else e.message
          # Roll back already executed operations.
          abort tx
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
      crdtManager.txCommit()
      true

    # Execute the transaction (or queue it if it arrived out of order).
    execute = (tx) =>
      # Add the transaction to the pending transactions cache.
      addPending tx

      while true
        # Find the first pending transaction that can be executed.
        # To preserve causality ('happened before'), we will have
        # to check whether the predecessor transactions of a
        # transaction have been executed.
        executableTx = null
        for pendingTx, i in pendingTxs
          # If for one of the operations, our local CRDT clock
          # happened-before the operation's base clock
          # then we are missing a prior transaction that this
          # transaction causally depends on.
          executableTx = pendingTx
          for op in pendingTx.operations
            crdt = crdtManager.findCrdt op.collection, op.crdtId
            lastClock = if crdt? then crdt.clock else {}
            if happenedBefore lastClock, op.baseClock
              # Do not execute the transaction
              executableTx = null
              break
          if executableTx?
            # We found an executable transaction, so
            # remove it from the pending transactions.
            pendingTxs.splice i, 1
            break
        return true unless executableTx?

        # Execute the transaction.
        initiatingSite = executableTx.initiatingSite
        Meteor.log.info 'transaction.nowExecuting',
          site: initiatingSite
          tx: getTxId(executableTx)
        return false unless doTransaction executableTx

        # If this is a local transaction that is not an undo
        # transaction itself then push it to the undo stack.
        if initiatingSite == localSite and not executableTx.isUndo
          undoStack.push executableTx.operations

    @undo = ->
      if undoStack.length == 0
        Meteor.log.info 'transaction.nothingToUndo'
        return

      # Get a transaction from the undo stack.
      undoTx = undoStack.pop()

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
      queueInternal undoOperations, true

      # Push the undone transaction onto the redo stack.
      redoStack.push undoTx

    @redo = ->
      if redoStack.length == 0
        Meteor.log.info 'transaction.nothingToRedo'
        return

      # Take the last undone transaction from the redo stack.
      redoTx = redoStack.pop()

      # Execute the redo transaction.
      queueInternal redoTx

    @_addOperation = (operation) -> currentOps.push operation

    @rollback = -> currentOps = []

    @commit = ->
      # Committing a new local transaction will delete the redo stack.
      redoStack = []

      # Queue the transaction for local and remote execution.
      queueInternal currentOps
      currentOps = []

    # On the server: Create the transactions log.
    if Meteor.isServer
      transactions = new Meteor.Collection 'transactions'
      @purgeLog = -> transactions.remove {}

    # Execute transactions in a meteor method so that
    # we can simulate their effect locally without latency
    # and without having to give clients write access to
    # the underlying collections.
    Meteor.methods
      _executeTx: (tx) ->
        # Log the transaction.
        tx._id = transactions.insert tx unless @isSimulation
        # Execute the transaction.
        execute tx

    # Queue and execute operations as a transaction.
    queueInternal = (operations, isUndo = false) =>
      # Advance the CRDT version clocks.
      for op in operations
        crdt = crdtManager.findCrdt op.collection, op.crdtId
        op.clock = ticTac crdt?.clock
      # Build the transaction.
      tx =
        initiatingSite: localSite
        isUndo: isUndo
        operations: operations
      # Execute the transaction.
      Meteor.call '_executeTx', tx


# Singleton
Meteor._TransactionsManager = new Meteor._TransactionsManager

# Add a shortcut
Meteor.tx = Meteor._TransactionsManager
