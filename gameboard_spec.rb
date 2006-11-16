require 'gameboard'
include Boggle

context "A new gameboard" do
  setup do
    @board = GameBoard.new
  end
  
  specify "should have a board_id" do
    @board.board_id.should_not_be_nil
  end

  specify "should supply a board" do
    @board.board.should_be_instance_of Array
  end

  specify "should yield board of size 25" do
    @board.board.size.should_be 25
  end
end

context "A new gameboard with specific board id" do
  setup do
    @board = GameBoard.new(101)
  end
  
  specify "should yield a specific board" do
    @board.board.should == %w{
      i e a d r
      s z n e d
      n r o a c
      a u e e s
      p a d o o
    }
  end
  
  specify "should include the word 'dread'" do
    @board.should_include 'dread'
  end
  
  specify "should include the word 'size'" do
    @board.should_include 'size'
  end

  specify "should not include the word 'sneer'" do
    @board.should_not_include 'sneer'
  end
  
  # this ensures that an ambiguous search path is successful
  specify "should include the word 'deaden'" do
    @board.should_include 'deaden'
  end

  specify "should include the word ''" do
    @board.should_include ''
  end
  
end

# specify some of the internal helper methods
context "The internal implementation of word_to_array" do
  setup do
    @board = GameBoard.new
    class << @board
      public :word_to_array
    end
  end
  specify "should correctly split 'random'" do
    @board.word_to_array('random').should == %w{r a n d o m}
  end
  specify "should correctly split 'quit'" do
    @board.word_to_array('quit').should == %w{qu i t}    
  end
  specify "should correctly split 'equestrian'" do
    @board.word_to_array('equestrian').should == %w{e qu e s t r i a n}
  end
  specify "should correctly split 'CaPiTAlIzED' (handles random capitalization)" do
    @board.word_to_array('CaPiTAlIzED').should == %w{c a p i t a l i z e d}
  end
  specify "should return an empty array for ''" do
    @board.word_to_array('').should == []
  end  
  
end