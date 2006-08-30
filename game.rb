$:.unshift File.expand_path(File.dirname(__FILE__) + "/lib")
require 'notification'
require 'gameboard'

module Boggle
  
  # state transitions:
  # nil state:
  # - does nothing
  # 
  # FindingState:
  # - created with game.start
  # - generates :times_up callback when complete (synchronous in separate thread)
  # 
  # VerifyingState:
  # - created by times_up method in game
  # - generates :verified callback when complete (synchronous)
  # - generates :game_over if applicable (synchronous)
  # 
  # VotingState:
  # - created by next_vote call, called from verified() (synchronous) or vote_completed() (async)
  # - generates :vote_complete when satisfied (asynchronous, relies on user input)
  # - generates :game_over if applicable (async)

  # Game's callbacks:
  # - :game_started(board_id)
  # - :times_up
  # - :verified(duplicates)
  # - :vote_required(word, player, reason)
  # - :vote_complete(final vote)
  
  class Game
    
    include Notification
    
    def initialize
      @state = nil
    end
    
    def running?
      !@state.nil?
    end
    
    def board
      @board ? @board.board : nil
    end
    
    def board_id
      @board ? @board.board_id : nil
    end
    
    def start(opts={})
      return if running?
      board_id = opts[:board_id]
      game_length = opts[:game_length] || 180 # seconds
      
      @board = GameBoard.new(board_id)
      board_id = @board.board_id
  
      @state = FindingState.new(game_length, @board)
      @state.add_observer self, :times_up
      notify :game_started, board_id
    end
    
    def cancel
      @state = nil
    end
    
    # straight-up delegations to the state
    def add_word(player, word)
      @state.add_word(player, word) if @state
    end
    def add_vote(player, vote)
      @state.add_vote(player, vote) if @state
    end
    
    # ----- callbacks -----
    def times_up(words)
      @found_word_counts = word_counts(words)
      @state = VerifyingState.new(words)
      @state.add_observer self, :verified
      notify :times_up
      @state.verify_words
    end
    
    def verified(wordlist)
      @words = wordlist[:words]
      @duplicates = wordlist[:duplicates]
      @rejected = wordlist[:rejected]
      total = @words.size + @duplicates.size + @rejected.size
      notify :verified, :total => total, :rejected => @rejected.size, :duplicates => @duplicates
      if @rejected && @rejected.size > 0
        @pending_votes = @rejected
        next_vote
      else
        game_over
      end
    end
    
    def vote_complete(vote)
      word, player, reason = @pending_votes.shift
      @words[player] << word if vote
      @pending_votes.size > 0 ? next_vote : game_over
    end
    
    private

    def next_vote
      game_over and return if @pending_votes.size == 0
      word, player, reason = @pending_votes.first
      @state = VotingState.new(word, player, @words.keys)
      @state.add_observer self, :vote_complete
      notify :vote_required, word, player, reason
    end
    
    def game_over
      @state = nil
      notify :game_over, final_score
    end
    
    def final_score
      final = [] # filled with [player, score, [words], total_words_found] sorted by score
      @words.each do |player, words|
        score = score(words)
        final << [player, score, words.sort.uniq, @found_word_counts[player] ]
      end
      final.sort {|x,y| y[1] <=> x[1] } # reverse sort based on score
    end

    def score(words)
      score = 0
      words.each do |word|
        score += case word.length
        when 0..3
          0
        when 4
          1
        when 5
          2
        when 6
          3
        when 7
          5
        else
          11
        end
      end
      score
    end
    
    def word_counts(wordlist)
      counts = {}
      wordlist.each do |player, words|
        counts[player] = words.map { |word| word.downcase }.uniq.size
      end
      counts
    end
        
  end

  class GameState # ignores things by default
    include Notification
    def add_word(player, word); end
    def add_vote(player, vote); end
  end
  
  class FindingState < GameState
    include Notification
    def initialize(timeout, board)
      @timeout = timeout
      @words = {}
      @board = board
      @thread = Thread.new do
        sleep @timeout
        begin
          notify :times_up, @words
        rescue Exception => e
          STDERR.puts 'e'
          e.backtrace.each { |bt| STDERR.puts bt }
        end
      end
    end
    
    def add_word(player, word)
      if word.size <= 3
        return 'word too short'
      elsif !@board.include?(word)
        return 'not on the board'
      else
        @words[player] ||= []
        @words[player] << word
        return nil
      end
    end
  end
  
  class VerifyingState < GameState
    def initialize(words)
      @words = words
    end
    
    def verify_words
      @rejected_words = []
      @duplicate_words = {}
      remove_duplicate_words
      check_aspell_words
      notify :verified, { :words => @words, 
                          :duplicates => @duplicate_words, 
                          :rejected => @rejected_words.sort_by { |word,player,msg| word } }
    end
    
    private
    
    def remove_duplicate_words
      all_words = {}
      @words.each_pair do |player, words|
        words.uniq!
        words.map! {|word| word.downcase }
        words.each do |word|
          (all_words[word] ||= []) << player
        end
      end
      all_words.each_pair do |word, players|
        if players.size > 1
          @duplicate_words[word] = players.sort
          players.each do |player|
            @words[player].delete(word)
          end
        end
      end
    end

    def check_aspell_words()
      return if @words.empty? # skip this if possible
      to_delete = []
      aspell = IO.popen('/usr/bin/env aspell -a', 'w+')
      aspell.gets # read in version string
      @words.each_pair do |player, words|
        words.each do |word|
          aspell.puts word
          response = aspell.gets
          aspell.gets # clear out the newline
          if response[0].chr != '*'
            msg = 'rejected by aspell'
            if response[0].chr == '&'
              splits = response.split(/\s+/)
              if splits[4] && splits[4].gsub(/[^A-Za-z]/, '') == word.capitalize
                msg += ', proper noun?'
              end
            end 
            to_delete << [player,word,msg]
          end
        end # each word
      end # each pair

      aspell.close # zombies BAD

      # now, process what needs to be deleted
      to_delete.each do |player, word, msg|
        @words[player].delete(word)
        @rejected_words << [word, player, msg] # hash is votes
      end

    end
  
  end
  
  class VotingState < GameState
    attr_reader :word
    def initialize(word, player, voters)
      @voters = voters
      @player = player
      @votes = {}
      @word = word
      @callback = false
    end
    
    def add_vote(player, vote)
      return unless @voters.include? player
      @votes[player] = vote
      if ( (player == @player && !vote) || vote_sufficient? ) && !@callback
        notify :vote_complete, final_vote 
        @callback = true
      end
    end
    
    private
    
    def vote_sufficient?
      players = @voters.size
      yes, no = calc_votes
      ( yes > players/2 ) || ( no >= (players/2.to_f).ceil )
    end
    
    def calc_votes
      yes = @votes.find_all {|player, vote| vote}.size
      no = @votes.find_all { |player, vote| !vote }.size
      [yes, no]
    end
    
    def final_vote
      players = @voters.size
      yes, no = calc_votes
      yes > players/2
    end
  end
  
end