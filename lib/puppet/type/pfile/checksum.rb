# Keep a copy of the file checksums, and notify when they change.

# This state never actually modifies the system, it only notices when the system
# changes on its own.
module Puppet
    Puppet.type(:file).newstate(:checksum) do
        desc "How to check whether a file has changed.  This state is used internally
            for file copying, but it can also be used to monitor files somewhat
            like Tripwire without managing the file contents in any way.  You can
            specify that a file's checksum should be monitored and then subscribe to
            the file from another object and receive events to signify
            checksum changes, for instance."

        @event = :file_changed

        @unmanaged = true

        @validtypes = %w{md5 md5lite timestamp mtime time}

        def self.validtype?(type)
            @validtypes.include?(type)
        end

        @validtypes.each do |ctype|
            newvalue(ctype) do
                handlesum()
            end
        end

        str = @validtypes.join("|")

        # This is here because Puppet sets this internally, using
        # {md5}......
        newvalue(/^\{#{str}\}/) do
            handlesum()
        end

        newvalue(:nosum) do
            # nothing
            :nochange
        end

        # If they pass us a sum type, behave normally, but if they pass
        # us a sum type + sum, stick the sum in the cache.
        munge do |value|
            if value =~ /^\{(\w+)\}(.+)$/
                type = symbolize($1)
                sum = $2
                cache(type, sum)
                return type
            else
                if FileTest.directory?(@parent[:path])
                    return :time
                else
                    return symbolize(value)
                end
            end
        end

        # Store the checksum in the data cache, or retrieve it if only the
        # sum type is provided.
        def cache(type, sum = nil)
            unless type
                raise ArgumentError, "A type must be specified to cache a checksum"
            end
            type = symbolize(type)
            unless state = @parent.cached(:checksums) 
                self.debug "Initializing checksum hash"
                state = {}
                @parent.cache(:checksums, state)
            end

            if sum
                unless sum =~ /\{\w+\}/
                    sum = "{%s}%s" % [type, sum]
                end
                state[type] = sum
            else
                return state[type]
            end
        end

        # Because source and content and whomever else need to set the checksum
        # and do the updating, we provide a simple mechanism for doing so.
        def checksum=(value)
            @is = value
            munge(@should)
            self.updatesum
        end

        def checktype
            self.should || :md5
        end

        # Checksums need to invert how changes are printed.
        def change_to_s
            begin
                if @is == :absent
                    return "defined '%s' as '%s'" %
                        [self.name, self.currentsum]
                elsif self.should == :absent
                    return "undefined %s from '%s'" %
                        [self.name, self.is_to_s]
                else
                    if defined? @cached and @cached
                        return "%s changed '%s' to '%s'" %
                            [self.name, @cached, self.is_to_s]
                    else
                        return "%s changed '%s' to '%s'" %
                            [self.name, self.currentsum, self.is_to_s]
                    end
                end
            rescue Puppet::Error, Puppet::DevError
                raise
            rescue => detail
                raise Puppet::DevError, "Could not convert change %s to string: %s" %
                    [self.name, detail]
            end
        end

        def currentsum
            #"{%s}%s" % [self.should, cache(self.should)]
            cache(checktype())
        end

        # Retrieve the cached sum
        def getcachedsum
            hash = nil
            unless hash = @parent.cached(:checksums) 
                hash = {}
                @parent.cache(:checksums, hash)
            end

            sumtype = self.should

            if hash.include?(sumtype)
                #self.notice "Found checksum %s for %s" %
                #    [hash[sumtype] ,@parent[:path]]
                sum = hash[sumtype]

                unless sum =~ /^\{\w+\}/
                    sum = "{%s}%s" % [sumtype, sum]
                end
                return sum
            elsif hash.empty?
                #self.notice "Could not find sum of type %s" % sumtype
                return :nosum
            else
                #self.notice "Found checksum for %s but not of type %s" %
                #    [@parent[:path],sumtype]
                return :nosum
            end
        end

        # Calculate the sum from disk.
        def getsum(checktype)
            sum = ""

            checktype = checktype.intern if checktype.is_a? String
            case checktype
            when :md5, :md5lite:
                if ! FileTest.file?(@parent[:path])
                    @parent.debug "Cannot MD5 sum %s; using mtime" %
                        [@parent.stat.ftype]
                    sum = @parent.stat.mtime.to_s
                else
                    begin
                        File.open(@parent[:path]) { |file|
                            text = nil
                            case checktype
                            when :md5
                                text = file.read
                            when :md5lite
                                text = file.read(512)
                            end

                            if text.nil?
                                self.debug "Not checksumming empty file %s" %
                                    @parent[:path]
                                sum = 0
                            else
                                sum = Digest::MD5.hexdigest(text)
                            end
                        }
                    rescue Errno::EACCES => detail
                        self.notice "Cannot checksum %s: permission denied" %
                            @parent[:path]
                        @parent.delete(self.class.name)
                    rescue => detail
                        self.notice "Cannot checksum: %s" %
                            detail
                        @parent.delete(self.class.name)
                    end
                end
            when :timestamp, :mtime:
                sum = @parent.stat.mtime.to_s
                #sum = File.stat(@parent[:path]).mtime.to_s
            when :time:
                sum = @parent.stat.ctime.to_s
                #sum = File.stat(@parent[:path]).ctime.to_s
            else
                raise Puppet::Error, "Invalid sum type %s" % checktype
            end

            return "{#{checktype}}" + sum.to_s
        end

        # At this point, we don't actually modify the system, we modify
        # the stored state to reflect the current state, and then kick
        # off an event to mark any changes.
        def handlesum
            if @is.nil?
                raise Puppet::Error, "Checksum state for %s is somehow nil" %
                    @parent.title
            end

            if @is == :absent
                self.retrieve

                if self.insync?
                    self.debug "Checksum is already in sync"
                    return nil
                end
                #@parent.debug "%s(%s): after refresh, is '%s'" %
                #    [self.class.name,@parent.name,@is]

                # If we still can't retrieve a checksum, it means that
                # the file still doesn't exist
                if @is == :absent
                    # if they're copying, then we won't worry about the file
                    # not existing yet
                    unless @parent.state(:source)
                        self.warning(
                            "File %s does not exist -- cannot checksum" %
                            @parent[:path]
                        )
                    end
                    return nil
                end
            end

            # If the sums are different, then return an event.
            if self.updatesum
                return :file_changed
            else
                return nil
            end
        end

        def insync?
            @should = [checktype]
            if cache(checktype())
                return @is == currentsum()
            else
                # If there's no cached sum, then we don't want to generate
                # an event.
                return true
            end
        end

        # Even though they can specify multiple checksums, the insync?
        # mechanism can really only test against one, so we'll just retrieve
        # the first specified sum type.
        def retrieve(usecache = false)
            # When the 'source' is retrieving, it passes "true" here so
            # that we aren't reading the file twice in quick succession, yo.
            if usecache and @is
                return @is
            end

            stat = nil
            unless stat = @parent.stat
                self.is = :absent
                return
            end

            if stat.ftype == "link" and @parent[:links] != :follow
                self.debug "Not checksumming symlink"
                #@parent.delete(:checksum)
                self.is = self.currentsum
                return
            end

            # Just use the first allowed check type
            @is = getsum(checktype())

            # If there is no sum defined, then store the current value
            # into the cache, so that we're not marked as being
            # out of sync.  We don't want to generate an event the first
            # time we get a sum.
            unless cache(checktype())
                # FIXME we should support an updatechecksums-like mechanism
                self.updatesum
            end

            #@parent.debug "checksum state is %s" % self.is
        end

        # Store the new sum to the state db.
        def updatesum
            result = false

            if @is.is_a?(Symbol)
                raise Puppet::Error, "%s has invalid checksum" % @parent.title
            end

            # if we're replacing, vs. updating
            if sum = cache(checktype())
                unless defined? @should
                    raise Puppet::Error.new(
                        ("@should is not initialized for %s, even though we " +
                        "found a checksum") % @parent[:path]
                    )
                end
                
                if @is == sum
                    info "Sums are already equal"
                    return false
                end

                #if cache(self.should) == @is
                #    raise Puppet::Error, "Got told to update same sum twice"
                #end
                self.debug "Replacing %s checksum %s with %s" %
                    [@parent.title, sum, @is]
                #@parent.debug "@is: %s; @should: %s" % [@is,@should]
                result = true
            else
                @parent.debug "Creating checksum %s" % @is
                result = false
            end

            # Cache the sum so the log message can be right if possible.
            @cached = sum
            cache(checktype(), @is)
            return result
        end
    end
end

# $Id$
