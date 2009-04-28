module DataMapper
  module Associations
    module ManyToMany #:nodoc:
      class Relationship < Associations::OneToMany::Relationship
        ##
        # Returns a set of keys that identify the target model
        #
        # @return [DataMapper::PropertySet]
        #   a set of properties that identify the target model
        #
        # @api semipublic
        def child_key
          @child_key ||=
            begin
              properties = target_model.properties(target_repository_name)

              child_key = if @child_properties
                properties.values_at(*@child_properties)
              else
                properties.key
              end

              properties.class.new(child_key).freeze
            end
        end

        alias target_key child_key

        # TODO: document
        # @api semipublic
        def through
          return @through if @through != Resource

          # habtm relationship traversal is deferred because we want the
          # target_model and source_model constants to be defined, so we
          # can define the join model within their common namespace

          @through = DataMapper.repository(source_repository_name) do
            join_model.belongs_to(join_relationship_name(target_model),          :model => target_model)
            source_model.has(min..max, join_relationship_name(join_model, true), :model => join_model)
          end

          # initialize the target_key now that the source and target model are defined
          @through.target_key

          @through
        end

        # TODO: document
        # @api semipublic
        def links
          @links ||=
            begin
              relationships = through.target_model.relationships(source_repository_name)

              unless target = relationships[name] || relationships[name.to_s.singular.to_sym]
                raise NameError, "Cannot find target relationship #{name} or #{name.to_s.singular} in #{through.target_model} within the #{source_repository_name.inspect} repository"
              end

              [ through, target ].map { |r| (l = r.links).any? ? l : r }.flatten.freeze
            end
        end

        # TODO: document
        # @api private
        def source_scope(source)
          # TODO: remove this method and inherit from Relationship

          target_key = through.target_key
          source_key = through.source_key

          scope = {}

          # TODO: handle compound keys
          if (source_values = Array(source).map { |r| source_key.first.get(r) }.compact).any?
            scope[target_key.first] = source_values
          end

          scope
        end

        # TODO: document
        # @api private
        def query
          # TODO: consider making this a query_for method, so that ManyToMany::Relationship#query only
          # returns the query supplied in the definition

          @many_to_many_query ||=
            begin
              # TODO: make sure the proper Query is set up, one that includes all the links
              #   - make sure that all relationships can be links
              #   - make sure that each intermediary can be at random repositories
              #   - make sure that each intermediary can have different conditons that
              #     scope its results

              query = super.dup

              # use all links in the query links
              query[:links] = links

              # TODO: move the logic below inside Query.  It should be
              # extracting the query conditions from each relationship itself

              repository_name = source_repository_name

              # merge the conditions from each intermediary into the query
              query[:links].each do |relationship|
                repository_name = relationship.target_repository_name || repository_name
                model           = relationship.target_model

                # TODO: try to do some of this normalization when
                # assigning the Query options to the Relationship

                relationship.query.each do |key, value|
                  # TODO: figure out how to merge Query options from links
                  if Query::OPTIONS.include?(key)
                    next  # skip for now
                  end

                  case key
                    when Symbol, String
                      # TODO: turn this into a Query::Path
                      query[model.properties(repository_name)[key]] = value

                    when Property
                      # TODO: turn this into a Query::Path
                      query[key] = value

                    when Query::Path
                      query[key] = value

                    when Query::Operator
                      # TODO: if the key.target is a Query::Path, then do not look it up
                      query[key.class.new(model.properties(repository_name)[key.target], key.operator)] = value

                    else
                      raise ArgumentError, "#{key.class} not allowed in relationship query"
                  end
                end
              end

              query.freeze
            end
        end

        private

        # TODO: document
        # @api private
        def join_model
          namespace, name = join_model_namespace_name

          if namespace.const_defined?(name)
            namespace.const_get(name)
          else
            model = Model.new do
              # all properties added to the anonymous join model are considered a key
              def property(name, type, options = {})
                options[:key] = true unless options.key?(:key)
                options.delete(:index)
                super
              end
            end

            namespace.const_set(name, model)
          end
        end

        # TODO: document
        # @api private
        def join_model_namespace_name
          target_parts = target_model.base_model.name.split('::')
          source_parts = source_model.base_model.name.split('::')

          name = [ target_parts.pop, source_parts.pop ].sort.join

          namespace = Object

          # find the common namespace between the target_model and source_model
          target_parts.zip(source_parts) do |target_part, source_part|
            break if target_part != source_part
            namespace = namespace.const_get(target_part)
          end

          return namespace, name
        end

        # TODO: document
        # @api private
        def join_relationship_name(model, plural = false)
          namespace = join_model_namespace_name.first
          relationship_name = Extlib::Inflection.underscore(model.base_model.name.sub(/\A#{namespace.name}::/, '')).gsub('/', '_')
          (plural ? relationship_name.plural : relationship_name).to_sym
        end

        # Returns collection class used by this type of
        # relationship
        #
        # @api private
        def collection_class
          ManyToMany::Collection
        end
      end # class Relationship

      class Collection < Associations::OneToMany::Collection
        # TODO: document
        # @api private
        attr_accessor :relationship

        # TODO: document
        # @api private
        attr_accessor :source

        # TODO: document
        # @api public
        def reload(query = nil)
          # TODO: remove *references* to the intermediaries
          # TODO: reload the collection
          raise NotImplementedError, "#{self.class}#reload not implemented"
        end

        # TODO: document
        # @api public
        def replace(other)
          # TODO: remove the left-most intermediary
          # TODO: replace the collection with other
          raise NotImplementedError, "#{self.class}#replace not implemented"
        end

        # TODO: document
        # @api public
        def clear
          # TODO: clear the intermediaries
          # TODO: clear the collection
          raise NotImplementedError, "#{self.class}#clear not implemented"
        end

        # TODO: document
        # @api public
        def create(attributes = {})
          assert_source_saved 'The source must be saved before creating a Resource'

          attributes = default_attributes.merge(attributes)
          links      = @relationship.links.dup
          midpoint   = nil

          head = [ source ]

          # walk the links from left to right, stopping at the midpoint
          until midpoint
            if (next_relationship = links[1]) && next_relationship.kind_of?(ManyToOne::Relationship)
              break midpoint = links[0, 2]
            end

            relationship = links.shift

            head << relationship.get(head.last).create(links.empty? ? attributes : {})

            # if all links have been processed, we are at the left-most
            # point, return the source as the target
            return head.last if links.empty?
          end

          tail = []

          # walk the links from the right to left, stopping at the midpoint
          until links.last == midpoint.first
            relationship = links.pop

            attributes = if tail.empty?
              attributes
            else
              relationship.source_scope(tail.first)
            end

            tail.unshift(relationship.target_model.create(attributes))

            # if all links have been processed return the target
            return tail.last if links.empty?
          end

          # handle the relationship at the midpoint
          lhs, rhs = midpoint
          default_attributes = rhs.source_key.map { |p| p.name }.zip(rhs.target_key.get(tail.first)).to_hash
          lhs.get(head.last).create(default_attributes)

          # always return the tail
          tail.last
        end

        # TODO: document
        # @api public
        def update(attributes = {})
          # TODO: update the resources in the target model
          raise NotImplementedError, "#{self.class}#update not implemented"
        end

        # TODO: document
        # @api public
        def update!(attributes = {})
          # TODO: update the resources in the target model
          raise NotImplementedError, "#{self.class}#update! not implemented"
        end

        # TODO: document
        # @api public
        def save
          # TODO: create the new intermediaries
          # TODO: destroy the orphaned intermediaries
          raise NotImplementedError, "#{self.class}#save not implemented"
        end

        # TODO: document
        # @api public
        def destroy
          # TODO: destroy the intermediaries
          # TODO: destroy the resources in the target model
          raise NotImplementedError, "#{self.class}#destroy not implemented"
        end

        # TODO: document
        # @api public
        def destroy!
          # TODO: destroy! the intermediaries
          # TODO: destroy! the resources in the target model
          raise NotImplementedError, "#{self.class}#destroy! not implemented"
        end

        private

        # TODO: document
        # @api private
        def relate_resource(resource)
          # TODO: queue up new intermediaries for creation

          # TODO: figure out how to DRY this up.  Should we just inherit
          # from Collection directly, and bypass OneToMany::Collection?
          return if resource.nil?

          resource.collection = self

          if resource.saved?
            @identity_map[resource.key] = resource
            @orphans.delete(resource)
          else
            resource.attributes = default_attributes.except(*resource.loaded_attributes.map { |p| p.name })
          end

          resource
        end

        # TODO: document
        # @api private
        def orphan_resource(resource)
          # TODO: figure out how to DRY this up.  Should we just inherit
          # from Collection directly, and bypass OneToMany::Collection?
          return if resource.nil?

          if resource.collection.equal?(self)
            resource.collection = nil
          end

          if resource.saved?
            @identity_map.delete(resource.key)
            @orphans << resource
          end

          resource
        end
      end # class Collection
    end # module ManyToMany
  end # module Associations
end # module DataMapper
