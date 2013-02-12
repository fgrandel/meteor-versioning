# A commutative replicative data type.
class Meteor._CrdtDocument
  constructor: (@collProps = null, serializedCrdt = null) ->
    if serializedCrdt?
      {
        crdtId: @crdtId
        clock: @clock
        properties: @_properties
        deleted: @_deleted
      } = serializedCrdt
    else
      @crdtId = undefined
      @clock = {}
      @_properties = []
      @_deleted = false

  # Inserts the payload to the end of the property list.
  # TODO: Deduplicate concurrent entries to the same property
  # from different sites. This can be done by passing the
  # corresponding tx's clock and initiatingSite value in
  # and ordering properties...
  # 1) for causally related tx: by happened-before relationship
  #  (this is automatic as transactions will be ordered causally)
  # 2) for concurrent tx: by site id
  # This will lead to a globally unique order (last write wins).
  # We just have to save the latest base clock. If new entries
  # come with the same base clock we need to dedup them by site id.
  # If we want to insert to the middle of the collection then
  # we need a more sophisticated index, see the binary tree
  # index implementation I had in the early versions of this
  # class (https://gist.github.com/jerico-dev/4566560).
  append: (payload, site) ->
    # Create a new entry.
    property =
      deleted: false
      payload: payload

    # Append the property to the crdt's property list.
    @_properties.push property

    # Return the index of the new property.
    @_properties.length - 1

  # Mark (entries for) the specified property deleted (invisible).
  #
  # locator:
  # - for Arrays: If an (integer) locator N is given, then
  #   only the N'th currently visible entry will be marked
  #   deleted.
  # - for Subdocs: If a (string) locator key:value is given, then
  #   all entries where the subkey 'key' equals 'value' of the
  #   object will be marked deleted.
  # - for Scalars: No locator can be given and all currently
  #   visible entries will be deleted.
  # In all cases: If no locator was given then all property
  # entries for that property will be marked deleted.
  delete: (key, locator = null) ->
    # Find all visible properties for this key.
    if locator? and @collProps[key]?.type == '[{}]' # Specific subdocuments.
      delProps = _.filter @_properties, (property) =>
        property.payload.key == key and
          property.payload.value[@collProps[key].locator] == locator and
          not property.deleted
    else # Scalar, Array or all Subdocuments
      delProps = _.filter @_properties, (property) =>
        property.payload.key == key and not property.deleted

    # Delete the specified entry or entries.
    if locator? and @collProps[key]?.type == '[*]' # A single array index.
      unless 0 <= locator < delProps.length
        Meteor.log.throw 'crdt.tryingToDeleteNonexistentKeyAtPos',
          {key:key, pos: locator, crdtId: @crdtId}
      delProps[locator].deleted = true
      # Return the index of the deleted entry.
      [_.indexOf @_properties, delProps[locator]]
    else # Scalar, (full) Array or Subdocuments
      if delProps.length == 0
        # This may happen when we have two concurrent delete operations
        # on exactly the same key. As this is not probable we log
        # a warning which may help to identify errors.
        Meteor.log.warning 'crdt.tryingToDeleteNonexistentKey',
          {key:key, crdtId: @crdtId}
      # Return the comprehension with the indices of all deleted entries.
      for delProp in delProps
        delProp.deleted = true
        _.indexOf @_properties, delProp

  _setDeleted: (index, forKey, deleted) ->
    if index >= @_properties.length
      Meteor.log.throw 'crdt.tryingToUnDeleteNonexistentIndex', index: index
    prop = @_properties[index]
    if prop.deleted == deleted
      # This may happen when two sites delete exactly the
      # same index concurrently. As this is not probable we
      # provide a warning as this may point to an error.
      Meteor.log.warning 'crdt.tryingToUnDeleteIndexInVisibleEntry',
        index: index
    if forKey? and prop.payload.key != forKey
      Meteor.log.throw 'crdt.tryingToUnDeleteIndexWithWrongKey',
        index: index, actualKey: prop.payload.key, shouldKey: forKey
    prop.deleted = deleted
    index

  # Mark the property at the given index deleted (invisible). The
  # second argument is redundant and just for consistency checking.
  deleteIndex: (index, forKey = null) ->
    @_setDeleted index, forKey, true

  # Mark the property at the given index not deleted (visible).
  undeleteIndex: (index, forKey = null) ->
    @_setDeleted index, forKey, false

  serialize: ->
    crdtId: @crdtId
    clock: @clock
    properties: @_properties
    deleted: @_deleted

  snapshot: ->
    if @_deleted
      null
    else
      snapshot = _id: @crdtId
      # Build properties but filter deleted entries.
      for prop in @_properties when not prop.deleted
        {key, value} = prop.payload
        switch @collProps[key]?.type
          when '[*]'
            # The value of this property is an array.
            snapshot[key] = [] unless snapshot[key]?
            snapshot[key].push value
          when '[{}]'
            # The value of this property is a collection of
            # subdocs with a unique key.
            subkey = value[@collProps[key].locator]
            snapshot[key] = {} unless snapshot[key]?
            snapshot[key][subkey] = value
          else
            # The value of this property is a scalar
            # (cardinality 0-1). We let later values
            # overwrite earlier ones.
            snapshot[key] = value
      # Transform lists of subdocuments to arrays.
      for collKey, collSpec of @collProps when collSpec.type = '[{}]'
        snapshot[collKey] = _.values snapshot[collKey]
      snapshot
