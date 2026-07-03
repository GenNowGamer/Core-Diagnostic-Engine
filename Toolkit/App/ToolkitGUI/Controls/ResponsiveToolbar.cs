using System.Windows;
using System.Windows.Controls;

namespace ToolkitGUI.Controls
{
    /// <summary>
    /// Horizontal toolbar that wraps buttons and controls onto multiple rows on narrow widths.
    /// </summary>
    public class ResponsiveToolbar : WrapPanel
    {
        public static readonly DependencyProperty ItemSpacingProperty =
            DependencyProperty.Register(
                nameof(ItemSpacing),
                typeof(Thickness),
                typeof(ResponsiveToolbar),
                new PropertyMetadata(new Thickness(0, 0, 8, 6)));

        public Thickness ItemSpacing
        {
            get => (Thickness)GetValue(ItemSpacingProperty);
            set => SetValue(ItemSpacingProperty, value);
        }

        public ResponsiveToolbar()
        {
            Orientation = Orientation.Horizontal;
        }
    }

}
