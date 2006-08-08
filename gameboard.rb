module Boggle
  
  class GameBoard
    
    CUBES = [ # for a 5x5 game
      %w{f y i p r s},
      %w{p t e l c i},
      %w{o n d l r h},
      %w{h h d l o r},
      %w{r o r v g w},
      %w{m e e e e a},
      %w{a e a e e e},
      %w{a a a f s r},
      %w{t c n e c s},
      %w{s a f r a i},
      %w{c r s i t e},
      %w{i i t e i t},
      %w{o n t d d h},
      %w{m a n n g e},
      %w{t o t t e m},
      %w{h o r d n l},
      %w{d e a n n n},
      %w{t o o o t u},
      %w{b k j x qu z},
      %w{c e t l i i},
      %w{s a r i f y},
      %w{r i r p y r},
      %w{u e g m a e},
      %w{s s s n e u},
      %w{n o o w t u}
    ]
    # ADVANCEDCUBE = %w{qu m l k u i}
    
    attr_reader :board_id, :board
    
    def initialize(board_id=nil)
      @board = create_board(board_id)
    end
    
    def include?(word)
      find_word word_to_array(word)
    end
    
    # ----- private -----
    private
    
    def create_board(board_id=nil)
      cubes = CUBES.dup
      board = []
      if board_id
        srand(board_id)
        @board_id = board_id
      else
        @board_id = rand(100000000)
        srand(@board_id)
      end
      while cubes.size > 0 do
        cube = cubes.delete_at(rand(cubes.size-1))
        board.push cube[rand(6)]
      end
      @board_size = 5 # hardcoded for now
      board
    end
    
    # ----- board search -----

    # recursive search:
    def find_word(word_array, visited=[], location=nil)
      # recursion end condition
      return true if word_array.size == 0 # easy case, empty words exist everywhere!

      cube = word_array.shift # get the first letter on the list
      
      locations = find_cube(cube, visited, location) # potential search locations
      
      found = false
      locations.each do |location|
        new_word = word_array.dup
        new_visited = visited.dup
        new_visited[location] = true
        found ||= find_word(new_word, new_visited, location) # recursive call
      end

      found
    end

    def find_cube(cube, visited, adjacent_to)
      found = []
      @board.each_with_index do |val, key|
        found << key if val == cube && !visited[key] && adjacent?(key, adjacent_to)
      end
      found
    end

    def adjacent? (key1, key2)
      return true unless key1 && key2 # any key is adjacent to nothingness! (nil)
      # do the search for key2 around key1 in a square grid
      key1x = key1 % @board_size # get the x position in the grid
      key1y = (key1-key1x) / @board_size # and the y position
      key2x = key2 % @board_size # x position of second key
      key2y = (key2-key2x) / @board_size # y position of second key
      # if the key x/y positions are within 1 of each other, then key2 is
      # in one of the 9 positions surrounding key1 (does not wrap!)
      (key1x-key2x).abs <= 1 && (key1y-key2y).abs <= 1 
    end

    # This could be implemented as String#to_array, but it's boggle-specific functionality.
    def word_to_array(word)
      word.downcase.scan /[a-pr-z]|qu/
    end
    
  end
  
end