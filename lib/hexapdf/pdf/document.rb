# -*- encoding: utf-8 -*-

require 'hexapdf/error'
require 'hexapdf/pdf/parser'
require 'hexapdf/pdf/reference'
require 'hexapdf/pdf/object'
require 'hexapdf/pdf/stream'
require 'hexapdf/pdf/revisions'
require 'hexapdf/pdf/type'

module HexaPDF
  module PDF

    # Represents one PDF document.
    #
    # A PDF document consists of (indirect) objects, so the main job of this class is to provide
    # methods for working with these objects. However, since a PDF document may also be
    # incrementally updated and can therefore contain one or more revisions, there are also methods
    # to work with these revisions.
    #
    # Note: This class provides everything to work on PDF documents on a low-level basis. This means
    # that there are no convenience methods for higher PDF functionality whatsoever.
    class Document

      # The default configuration for a PDF document.
      #
      # The configuration contains options that can change the built-in behavior of the base classes
      # on which a document is built or which are used to read or write it.
      #
      # Available configuration keys:
      #
      # filter.map::
      #    A mapping from a PDF name (a Symbol) to a filter object (see Filter). If the value is a
      #    String, it should contain the name of a constant that contains a filter object.
      #
      # object.map::
      #    A mapping from [Type, Subtype] entries to PDF object classes. If the value is a String,
      #    it should contain the name of a constant that contains a PDF object class.
      #
      #    This mapping is used to provide automatic wrapping of objects in the #wrap method.
      #
      # io.chunk_size::
      #    The size of the chunks that are used when reading IO data.
      #
      #    This can be used to limit the memory needed for reading or writing PDF files with huge
      #    stream objects.
      def self.default_config
        {
          # See PDF1.7 s7.4.1, ADB sH.3 3.3
          'filter.map' => {
            ASCIIHexDecode: 'HexaPDF::PDF::Filter::ASCIIHexDecode',
            AHx: 'HexaPDF::PDF::Filter::ASCIIHexDecode',
            ASCII85Decode: 'HexaPDF::PDF::Filter::ASCII85Decode',
            A85: 'HexaPDF::PDF::Filter::ASCII85Decode',
            LZWDecode: 'HexaPDF::PDF::Filter::LZWDecode',
            LZW: 'HexaPDF::PDF::Filter::LZWDecode',
            FlateDecode: 'HexaPDF::PDF::Filter::FlateDecode',
            Fl: 'HexaPDF::PDF::Filter::FlateDecode',
            RunLengthDecode: 'HexaPDF::PDF::Filter::RunLengthDecode',
            RL: 'HexaPDF::PDF::Filter::RunLengthDecode',
            CCITTFaxDecode: nil,
            CCF: nil,
            JBIG2Decode: nil,
            DCTDecode: 'HexaPDF::PDF::Filter::DCTDecode',
            DCT: 'HexaPDF::PDF::Filter::DCTDecode',
            JPXDecode: 'HexaPDF::PDF::Filter::JPXDecode',
            Crypt: nil
          },
          'object.map' => {
            [:XRef, nil] => 'HexaPDF::PDF::Type::XRefStream',
            [:ObjStm, nil] => 'HexaPDF::PDF::Type::ObjectStream',
          },
          'io.chunk_size' => 2**16,
          'parser.strict' => false,
        }
      end

      # The configuration for the document.
      attr_reader :config

      # The revisions of the document.
      attr_reader :revisions

      # The associated parser if any.
      attr_reader :parser

      # Creates a new PDF document.
      #
      # Options:
      #
      # io:: If an IO object is provided, then this document can read PDF objects from this IO
      #      object, otherwise it can only contain created PDF objects.
      #
      # config:: A hash with configuration options that is deep-merged into the default
      #          configuration options hash (see ::default_config), meaning that direct sub-hashes
      #          are merged instead of overwritten.
      def initialize(io: nil, config: {})
        @config = self.class.default_config.merge(config) do |k, old, new|
          old.kind_of?(Hash) && new.kind_of?(Hash) ? old.merge(new) : new
        end

        if io
          @parser = Parser.new(io, self)
          @revisions = Revisions.new(self, initial_revision: @parser.load_revision(@parser.startxref_offset))
        else
          @parser = :no_parser_available
          @revisions = Revisions.new(self)
        end

        @next_oid = @revisions.current.trailer.value[:Size] || 1
      end

      # :call-seq:
      #   doc.object(ref)    -> obj or nil
      #   doc.object(oid)    -> obj or nil
      #
      # Returns the current version of the indirect object for the given exact reference or for the
      # given object number.
      #
      # For references to unknown objects, +nil+ is returned but free objects are represented by a
      # PDF Null object, not by +nil+!
      #
      # See: PDF1.7 s7.3.9
      def object(ref)
        oid = (ref.respond_to?(:oid) ? ref.oid : ref)

        obj = nil
        @revisions.each do |rev|
          # Check uses oid because we are only interested in the current version of an object with a
          # given object number!
          next unless rev.object?(oid)
          obj = rev.object(ref)
          break
        end
        obj
      end

      # Dereferences the given object.
      #
      # Return the object itself if it is not a reference, or the indirect object specified by the
      # reference.
      def deref(obj)
        obj.kind_of?(Reference) ? object(obj) : obj
      end

      # :call-seq:
      #   doc.object?(ref)    -> true or false
      #   doc.object?(oid)    -> true or false
      #
      # Returns +true+ if the the document contains an indirect object for the given exact reference
      # or for the given object number.
      #
      # Even though this method might return +true+ for some references, #object may return +nil+
      # because this method takes *all* revisions into account. Also see the discussion on #each for
      # more information.
      def object?(ref)
        @revisions.any? {|rev| rev.object?(ref)}
      end

      # :call-seq:
      #   doc.add(obj, revision: :current)     -> indirect_object
      #
      # Adds the object to the specified revision of the document and returns the wrapped indirect
      # object.
      #
      # If the +revision+ option is +:current+, the current revision is used. Otherwise +revision+
      # should be a revision index.
      #
      # The object can either be a native Ruby object (Hash, Array, Integer, ...) or a
      # HexaPDF::PDF::Object.
      def add(obj, revision: :current)
        obj = wrap(obj) unless obj.kind_of?(HexaPDF::PDF::Object)

        revision = (revision == :current ? @revisions.current : @revisions.revision(revision))
        if revision.nil?
          raise HexaPDF::Error, "Invalid revision index specified"
        end

        if obj.document? && obj.document != self
          raise HexaPDF::Error, "Can't add object that is already attached to another document"
        end
        obj.document = self

        if obj.oid != 0 && (rev_obj = revision.object(obj.oid))
          if rev_obj.equal?(obj)
            return obj
          else
            raise HexaPDF::Error, "Can't add object because the specified revision already has an object " +
              "with object number #{obj.oid}"
          end
        end

        if obj.oid == 0
          obj.oid = @next_oid
          @next_oid += 1
        end

        revision.add(obj)
      end

      # :call-seq:
      #   doc.delete(ref, revision: :all)
      #   doc.delete(oid, revision: :all)
      #
      # Deletes the indirect object specified by an exact reference or by an object number from the
      # document.
      #
      # Options:
      #
      # revision:: Specifies from which revisions the object should be deleted:
      #
      #            :all:: Delete the object from all revisions.
      #            :current:: Delete the object only from the current revision.
      #
      # mark_as_free:: If +true+, objects are only marked as free objects instead of being actually
      #                deleted.
      def delete(ref, revision: :all, mark_as_free: true)
        case revision
        when :current
          @revisions.current.delete(ref, mark_as_free: mark_as_free)
        when :all
          @revisions.each {|rev| rev.delete(ref, mark_as_free: mark_as_free)}
        else
          raise HexaPDF::Error, "Unsupported option revision=#{revision}"
        end
      end

      # Wraps the given object inside a HexaPDF::PDF::Object class which allows one to use
      # convenience functions to work with the object.
      #
      # The +obj+ argument can also be a HexaPDF::PDF::Object object so that it can be re-wrapped if
      # needed.
      #
      # The class of the returned object is always a subclass of HexaPDF::PDF::Object (or of
      # HexaPDF::PDF::Stream if a +stream+ is given). Which subclass is used, depends on the values
      # of the +type+ and +subtype+ options and the 'object.map' configuration option.
      #
      # Options:
      #
      # :type:: (Symbol) The type of a PDF object that should be used for wrapping. This could be,
      #         for example, :Pages.
      #
      # :sub_type:: (Symbol) The subtype of a PDF object which further qualifies a type. For
      #             example, image objects in PDF have a type of :XObject and a subtype of :Image.
      #
      # :oid:: (Integer) The object number that should be set on the wrapped object. Defaults to 0
      #        or the value of the given object's object number.
      #
      # :gen:: (Integer) The generation number that should be set on the wrapped object. Defaults to
      #        0 or the value of the given object's generation number.
      #
      # :stream:: (String or StreamData) The stream object which should be set on the wrapped
      #           object.
      def wrap(obj, type: nil, subtype: nil, oid: nil, gen: nil, stream: nil)
        if obj.kind_of?(HexaPDF::PDF::Object)
          oid ||= obj.oid
          gen ||= obj.gen
          stream ||= obj.raw_stream
          obj = obj.value
        end

        default = (stream ? HexaPDF::PDF::Stream : HexaPDF::PDF::Object)
        if obj.kind_of?(Hash)
          type ||= obj[:Type]
          subtype ||= obj[:Subtype]
        end

        klass = config['object.map'][[type, subtype]] || default
        klass = ::Object.const_get(klass) if klass.kind_of?(String)

        obj = klass.new(obj, document: self)
        obj.oid = oid if oid
        obj.gen = gen if gen
        obj.stream = stream if stream
        obj
      end

      # Recursively unwraps the object to get native Ruby objects (i.e. Hash, Array, Integer, ...
      # instead of HexaPDF::PDF::Reference and HexaPDF::PDF::Object).
      def unwrap(obj)
        recurse = lambda do |object, seen|
          object = deref(object)
          if seen.key?(object)
            raise HexaPDF::Error, "Can't unwrap a recursive structure"
          end

          case object
          when Hash
            seen[object] = true
            object.each_with_object({}) {|(key, val), memo| memo[key] = recurse.call(val, seen)}
          when Array
            seen[object] = true
            object.map {|inner_o| recurse.call(inner_o, seen)}
          when HexaPDF::PDF::Object
            seen[object] = true
            recurse.call(object.value, seen)
          else
            object
          end
        end
        recurse.call(obj, {})
      end

      # :call-seq:
      #   doc.each(current: true) {|obj| block }   -> doc
      #   doc.each(current: true)                  -> Enumerator
      #
      # Calls the given block once for every object in the PDF document.
      #
      # By default, only the current version of each object is returned which implies that each
      # object number is yielded exactly once. If the +current+ option is +false+, all stored
      # objects from newest to oldest are returned, not only the current version of each object.
      #
      # The +current+ option can make a difference because the document can contain multiple
      # revisions:
      #
      # * Multiple revisions may contain objects with the same object and generation numbers, e.g.
      #   two (different) objects with oid/gen [3,0].
      #
      # * Additionally, there may also be objects with the same object number but different
      #   generation numbers in different revisions, e.g. one object with oid/gen [3,0] and one with
      #   oid/gen [3,1].
      def each(current: true)
        return to_enum(__method__, current: current) unless block_given?

        oids = {}
        @revisions.each do |rev|
          rev.each do |obj|
            next if current && oids.include?(obj.oid)
            yield(obj)
            oids[obj.oid] = true
          end
        end
        self
      end

    end

  end
end